{-# LANGUAGE OverloadedStrings #-}

module Generate.JavaScript
  ( GeneratedResult (..),
    generate,
    generateForRepl,
  )
where

import AST.Canonical qualified as Can
import AST.Optimized qualified as Opt
import Data.ByteString.Builder qualified as B
import Data.ByteString.Lazy.Char8 qualified as BLazy
import Data.Index qualified as Index
import Data.List qualified as List
import Data.Map ((!))
import Data.Map qualified as Map
import Data.Name qualified as Name
import Data.Set qualified as Set
import Data.Utf8 qualified as Utf8
import Generate.JavaScript.Builder qualified as JS
import Generate.JavaScript.Expression qualified as Expr
import Generate.JavaScript.Functions qualified as Functions
import Generate.JavaScript.Name qualified as JsName
import Generate.Mode qualified as Mode
import Generate.SourceMap qualified as SourceMap
import Gren.Kernel qualified as K
import Gren.ModuleName qualified as ModuleName
import Reporting.Doc qualified as D
import Reporting.Render.Type qualified as RT
import Reporting.Render.Type.Localizer qualified as L
import Prelude hiding (cycle, print)

-- GENERATE

type Graph = Map.Map Opt.Global Opt.Node

type Mains = Map.Map ModuleName.Canonical Opt.Main

data GeneratedResult = GeneratedResult
  { _source :: B.Builder,
    _sourceMap :: SourceMap.SourceMap
  }

prelude :: B.Builder
prelude =
  "(function(scope){\n'use strict';"
    <> Functions.functions

firstGeneratedLineNumber :: Int
firstGeneratedLineNumber =
  length $ lines $ BLazy.unpack $ B.toLazyByteString prelude

generate :: Mode.Mode -> Opt.GlobalGraph -> Mains -> GeneratedResult
generate mode (Opt.GlobalGraph graph _) mains =
  let state = Map.foldrWithKey (addMain mode graph) (emptyState firstGeneratedLineNumber) mains
      builder =
        prelude
          <> stateToBuilder state
          <> toMainExports mode mains
          <> "}(this.module ? this.module.exports : this));"
      sourceMap = SourceMap.generate $ stateToMappings state
   in GeneratedResult
        { _source = builder,
          _sourceMap = sourceMap
        }

addMain :: Mode.Mode -> Graph -> ModuleName.Canonical -> Opt.Main -> State -> State
addMain mode graph home _ state =
  addGlobal mode graph state (Opt.Global home "main")

-- GENERATE FOR REPL

generateForRepl :: Bool -> L.Localizer -> Opt.GlobalGraph -> ModuleName.Canonical -> Name.Name -> Can.Annotation -> B.Builder
generateForRepl ansi localizer (Opt.GlobalGraph graph _) home name (Can.Forall _ tipe) =
  let mode = Mode.Dev Nothing
      debugState = addGlobal mode graph (emptyState 0) (Opt.Global ModuleName.debug "toString")
      evalState = addGlobal mode graph debugState (Opt.Global home name)
   in "process.on('uncaughtException', function(err) { process.stderr.write(err.toString() + '\\n'); process.exit(1); });"
        <> Functions.functions
        <> stateToBuilder evalState
        <> print ansi localizer home name tipe

print :: Bool -> L.Localizer -> ModuleName.Canonical -> Name.Name -> Can.Type -> B.Builder
print ansi localizer home name tipe =
  let value = JsName.toBuilder (JsName.fromGlobal home name)
      toString = JsName.toBuilder (JsName.fromKernel Name.debug "toAnsiString")
      tipeDoc = RT.canToDoc localizer RT.None tipe
      bool = if ansi then "true" else "false"
   in "var _value = "
        <> toString
        <> "("
        <> bool
        <> ", "
        <> value
        <> ");\n\
           \var _type = "
        <> B.stringUtf8 (show (D.toString tipeDoc))
        <> ";\n\
           \function _print(t) { console.log(_value + ("
        <> bool
        <> " ? '\x1b[90m' + t + '\x1b[0m' : t)); }\n\
           \if (_value.length + 3 + _type.length >= 80 || _type.indexOf('\\n') >= 0) {\n\
           \    _print('\\n    : ' + _type.split('\\n').join('\\n      '));\n\
           \} else {\n\
           \    _print(' : ' + _type);\n\
           \}\n"

-- GRAPH TRAVERSAL STATE

data State = State
  { _seenGlobals :: Set.Set Opt.Global,
    _builder :: JS.Builder
  }

emptyState :: Int -> State
emptyState startingLine =
  State Set.empty (JS.emptyBuilder startingLine)

stateToBuilder :: State -> B.Builder
stateToBuilder (State _ builder) =
  JS._code builder

stateToMappings :: State -> [JS.Mapping]
stateToMappings (State _ builder) =
  JS._mappings builder

-- ADD DEPENDENCIES

addGlobal :: Mode.Mode -> Graph -> State -> Opt.Global -> State
addGlobal mode graph state@(State seen builder) global =
  if Set.member global seen
    then state
    else
      addGlobalHelp mode graph global $
        State (Set.insert global seen) builder

addGlobalHelp :: Mode.Mode -> Graph -> Opt.Global -> State -> State
addGlobalHelp mode graph global state =
  let addDeps deps someState =
        Set.foldl' (addGlobal mode graph) someState deps
   in case graph ! global of
        Opt.Define expr deps ->
          addStmt
            (addDeps deps state)
            ( var global (Expr.generate mode expr)
            )
        Opt.DefineTailFunc argNames body deps ->
          addStmt
            (addDeps deps state)
            ( let (Opt.Global _ name) = global
               in var global (Expr.generateTailDef mode name argNames body)
            )
        Opt.Ctor index arity ->
          addStmt
            state
            ( var global (Expr.generateCtor mode global index arity)
            )
        Opt.Link linkedGlobal ->
          addGlobal mode graph state linkedGlobal
        Opt.Cycle names values functions deps ->
          addStmt
            (addDeps deps state)
            ( generateCycle mode global names values functions
            )
        Opt.Manager effectsType ->
          generateManager mode graph global effectsType state
        Opt.Kernel chunks deps ->
          if isDebugger global && not (Mode.isDebug mode)
            then state
            else addDeps deps (addKernel state (generateKernel mode chunks))
        Opt.Enum index ->
          addStmt
            state
            ( generateEnum mode global index
            )
        Opt.Box ->
          addStmt
            (addGlobal mode graph state identity)
            ( generateBox mode global
            )
        Opt.PortIncoming decoder deps ->
          addStmt
            (addDeps deps state)
            ( generatePort mode global "incomingPort" decoder
            )
        Opt.PortOutgoing encoder deps ->
          addStmt
            (addDeps deps state)
            ( generatePort mode global "outgoingPort" encoder
            )

addStmt :: State -> JS.Stmt -> State
addStmt (State seen builder) stmt =
  State seen (JS.stmtToBuilder stmt builder)

addKernel :: State -> B.Builder -> State
addKernel (State seen builder) kernel =
  State seen (JS.addByteString kernel builder)

var :: Opt.Global -> Expr.Code -> JS.Stmt
var (Opt.Global home name) code =
  JS.Var (JsName.fromGlobal home name) (Expr.codeToExpr code)

isDebugger :: Opt.Global -> Bool
isDebugger (Opt.Global (ModuleName.Canonical _ home) _) =
  home == Name.debugger

-- GENERATE CYCLES

generateCycle :: Mode.Mode -> Opt.Global -> [Name.Name] -> [(Name.Name, Opt.Expr)] -> [Opt.Def] -> JS.Stmt
generateCycle mode (Opt.Global home _) names values functions =
  JS.Block
    [ JS.Block $ map (generateCycleFunc mode home) functions,
      JS.Block $ map (generateSafeCycle mode home) values,
      case map (generateRealCycle home) values of
        [] ->
          JS.EmptyStmt
        realBlock@(_ : _) ->
          case mode of
            Mode.Prod _ ->
              JS.Block realBlock
            Mode.Dev _ ->
              JS.Try (JS.Block realBlock) JsName.dollar $
                JS.Throw $
                  JS.String $
                    "Some top-level definitions from `"
                      <> Name.toBuilder (ModuleName._module home)
                      <> "` are causing infinite recursion:\\n"
                      <> drawCycle names
                      <> "\\n\\nThese errors are very tricky, so read "
                      <> B.stringUtf8 (D.makeNakedLink "bad-recursion")
                      <> " to learn how to fix it!"
    ]

generateCycleFunc :: Mode.Mode -> ModuleName.Canonical -> Opt.Def -> JS.Stmt
generateCycleFunc mode home def =
  case def of
    Opt.Def name expr ->
      JS.Var (JsName.fromGlobal home name) (Expr.codeToExpr (Expr.generate mode expr))
    Opt.TailDef name args expr ->
      JS.Var (JsName.fromGlobal home name) (Expr.codeToExpr (Expr.generateTailDef mode name args expr))

generateSafeCycle :: Mode.Mode -> ModuleName.Canonical -> (Name.Name, Opt.Expr) -> JS.Stmt
generateSafeCycle mode home (name, expr) =
  JS.FunctionStmt (JsName.fromCycle home name) [] $
    Expr.codeToStmtList (Expr.generate mode expr)

generateRealCycle :: ModuleName.Canonical -> (Name.Name, expr) -> JS.Stmt
generateRealCycle home (name, _) =
  let safeName = JsName.fromCycle home name
      realName = JsName.fromGlobal home name
   in JS.Block
        [ JS.Var realName (JS.Call (JS.Ref safeName) []),
          JS.ExprStmt $
            JS.Assign (JS.LRef safeName) $
              JS.Function Nothing [] [JS.Return (JS.Ref realName)]
        ]

drawCycle :: [Name.Name] -> B.Builder
drawCycle names =
  let topLine = "\\n  ┌─────┐"
      nameLine name = "\\n  │    " <> Name.toBuilder name
      midLine = "\\n  │     ↓"
      bottomLine = "\\n  └─────┘"
   in mconcat (topLine : List.intersperse midLine (map nameLine names) ++ [bottomLine])

-- GENERATE KERNEL

generateKernel :: Mode.Mode -> [K.Chunk] -> B.Builder
generateKernel mode chunks =
  List.foldr (addChunk mode) mempty chunks

addChunk :: Mode.Mode -> K.Chunk -> B.Builder -> B.Builder
addChunk mode chunk builder =
  case chunk of
    K.JS javascript ->
      B.byteString javascript <> builder
    K.GrenVar home name ->
      JsName.toBuilder (JsName.fromGlobal home name) <> builder
    K.JsVar home name ->
      JsName.toBuilder (JsName.fromKernel home name) <> builder
    K.GrenField name ->
      JsName.toBuilder (Expr.generateField mode name) <> builder
    K.JsField int ->
      JsName.toBuilder (JsName.fromInt int) <> builder
    K.JsEnum int ->
      B.intDec int <> builder
    K.Debug ->
      case mode of
        Mode.Dev _ ->
          builder
        Mode.Prod _ ->
          "_UNUSED" <> builder
    K.Prod ->
      case mode of
        Mode.Dev _ ->
          "_UNUSED" <> builder
        Mode.Prod _ ->
          builder

-- GENERATE ENUM

generateEnum :: Mode.Mode -> Opt.Global -> Index.ZeroBased -> JS.Stmt
generateEnum mode global@(Opt.Global home name) index =
  JS.Var (JsName.fromGlobal home name) $
    case mode of
      Mode.Dev _ ->
        Expr.codeToExpr (Expr.generateCtor mode global index 0)
      Mode.Prod _ ->
        JS.Int (Index.toMachine index)

-- GENERATE BOX

generateBox :: Mode.Mode -> Opt.Global -> JS.Stmt
generateBox mode global@(Opt.Global home name) =
  JS.Var (JsName.fromGlobal home name) $
    case mode of
      Mode.Dev _ ->
        Expr.codeToExpr (Expr.generateCtor mode global Index.first 1)
      Mode.Prod _ ->
        JS.Ref (JsName.fromGlobal ModuleName.basics Name.identity)

identity :: Opt.Global
identity =
  Opt.Global ModuleName.basics Name.identity

-- GENERATE PORTS

generatePort :: Mode.Mode -> Opt.Global -> Name.Name -> Opt.Expr -> JS.Stmt
generatePort mode (Opt.Global home name) makePort converter =
  JS.Var (JsName.fromGlobal home name) $
    JS.Call
      (JS.Ref (JsName.fromKernel Name.platform makePort))
      [ JS.String (Name.toBuilder name),
        Expr.codeToExpr (Expr.generate mode converter)
      ]

-- GENERATE MANAGER

generateManager :: Mode.Mode -> Graph -> Opt.Global -> Opt.EffectsType -> State -> State
generateManager mode graph (Opt.Global home@(ModuleName.Canonical _ moduleName) _) effectsType state =
  let managerLVar =
        JS.LBracket
          (JS.Ref (JsName.fromKernel Name.platform "effectManagers"))
          (JS.String (Name.toBuilder moduleName))

      (deps, args, stmts) =
        generateManagerHelp home effectsType

      createManager =
        JS.ExprStmt $
          JS.Assign managerLVar $
            JS.Call (JS.Ref (JsName.fromKernel Name.platform "createManager")) args
   in addStmt (List.foldl' (addGlobal mode graph) state deps) $
        JS.Block (createManager : stmts)

generateLeaf :: ModuleName.Canonical -> Name.Name -> JS.Stmt
generateLeaf home@(ModuleName.Canonical _ moduleName) name =
  JS.Var (JsName.fromGlobal home name) $
    JS.Call leaf [JS.String (Name.toBuilder moduleName)]

leaf :: JS.Expr
leaf =
  JS.Ref (JsName.fromKernel Name.platform "leaf")

generateManagerHelp :: ModuleName.Canonical -> Opt.EffectsType -> ([Opt.Global], [JS.Expr], [JS.Stmt])
generateManagerHelp home effectsType =
  let dep name = Opt.Global home name
      ref name = JS.Ref (JsName.fromGlobal home name)
   in case effectsType of
        Opt.Cmd ->
          ( [dep "init", dep "onEffects", dep "onSelfMsg", dep "cmdMap"],
            [ref "init", ref "onEffects", ref "onSelfMsg", ref "cmdMap"],
            [generateLeaf home "command"]
          )
        Opt.Sub ->
          ( [dep "init", dep "onEffects", dep "onSelfMsg", dep "subMap"],
            [ref "init", ref "onEffects", ref "onSelfMsg", JS.Int 0, ref "subMap"],
            [generateLeaf home "subscription"]
          )
        Opt.Fx ->
          ( [dep "init", dep "onEffects", dep "onSelfMsg", dep "cmdMap", dep "subMap"],
            [ref "init", ref "onEffects", ref "onSelfMsg", ref "cmdMap", ref "subMap"],
            [ generateLeaf home "command",
              generateLeaf home "subscription"
            ]
          )

-- MAIN EXPORTS

toMainExports :: Mode.Mode -> Mains -> B.Builder
toMainExports mode mains =
  let export = JsName.fromKernel Name.platform "export"
      exports = generateExports mode (Map.foldrWithKey addToTrie emptyTrie mains)
   in JsName.toBuilder export <> "(" <> exports <> ");"

generateExports :: Mode.Mode -> Trie -> B.Builder
generateExports mode (Trie maybeMain subs) =
  let starter end =
        case maybeMain of
          Nothing ->
            "{"
          Just (home, main) ->
            "{'init':"
              <> JS._code (JS.exprToBuilder (Expr.generateMain mode home main) (JS.emptyBuilder 0))
              <> end
   in case Map.toList subs of
        [] ->
          starter "" <> "}"
        (name, subTrie) : otherSubTries ->
          starter ","
            <> "'"
            <> Utf8.toBuilder name
            <> "':"
            <> generateExports mode subTrie
            <> List.foldl' (addSubTrie mode) "}" otherSubTries

addSubTrie :: Mode.Mode -> B.Builder -> (Name.Name, Trie) -> B.Builder
addSubTrie mode end (name, trie) =
  ",'" <> Utf8.toBuilder name <> "':" <> generateExports mode trie <> end

-- BUILD TRIES

data Trie = Trie
  { _main :: Maybe (ModuleName.Canonical, Opt.Main),
    _subs :: Map.Map Name.Name Trie
  }

emptyTrie :: Trie
emptyTrie =
  Trie Nothing Map.empty

addToTrie :: ModuleName.Canonical -> Opt.Main -> Trie -> Trie
addToTrie home@(ModuleName.Canonical _ moduleName) main trie =
  merge trie $ segmentsToTrie home (Name.splitDots moduleName) main

segmentsToTrie :: ModuleName.Canonical -> [Name.Name] -> Opt.Main -> Trie
segmentsToTrie home segments main =
  case segments of
    [] ->
      Trie (Just (home, main)) Map.empty
    segment : otherSegments ->
      Trie Nothing (Map.singleton segment (segmentsToTrie home otherSegments main))

merge :: Trie -> Trie -> Trie
merge (Trie main1 subs1) (Trie main2 subs2) =
  Trie
    (checkedMerge main1 main2)
    (Map.unionWith merge subs1 subs2)

checkedMerge :: Maybe a -> Maybe a -> Maybe a
checkedMerge a b =
  case (a, b) of
    (Nothing, main) ->
      main
    (main, Nothing) ->
      main
    (Just _, Just _) ->
      error "cannot have two modules with the same name"
