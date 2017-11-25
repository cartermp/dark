module Entry exposing (..)

-- builtins
import Task
-- import Result exposing (Result)
import Dict
-- import Set

-- lib
import Dom
-- import Result.Extra as RE
-- import Maybe.Extra as ME

-- dark
-- import Util
import Defaults
import Types exposing (..)
-- import Autocomplete
import Viewport
-- import EntryParser exposing (AST(..), ACreating(..), AExpr(..), AFillParam(..), AFillResult(..), ARef(..))
import Util
import AST
import Toplevel as TL
import Runtime as RT
import Analysis


---------------------
-- Nodes
---------------------
updateValue : String -> Modification
updateValue target =
  Many [ AutocompleteMod <| ACSetQuery target ]

createFindSpace : Model -> Modification
createFindSpace m = Enter False <| Creating (Viewport.toAbsolute m Defaults.initialPos)
---------------------
-- Focus
---------------------

focusEntry : Cmd Msg
focusEntry = Dom.focus Defaults.entryID |> Task.attempt FocusEntry


---------------------
-- Submitting the entry form to the server
---------------------
-- refocus : Bool -> Focus -> Focus
-- refocus re default =
--   case default of
--     FocusNext id -> if re then Refocus id else default
--     FocusExact id -> if re then Refocus id else default
--     f -> f
--

tlid : () -> TLID
tlid unit = TLID (Util.random unit)

gid : () -> ID -- Generate ID
gid unit = ID (Util.random unit)

createFunction : Model -> FnName -> Maybe Expr
createFunction m name =
  let holes count = List.map (\_ -> Hole (gid ())) (List.range 1 count)
      fn = m.complete.functions
           |> List.filter (\fn -> fn.name == name)
           |> List.head
  in
    case fn of
      Just function ->
        Just <| FnCall (gid ()) name (holes (List.length function.parameters))
      Nothing -> Nothing

submit : Model -> Bool -> EntryCursor -> String -> Modification
submit m re cursor value =
  let id = tlid ()
      eid = gid ()
      tid1 = gid ()
      tid2 = gid ()
      tid3 = gid ()
      hid1 = gid ()
      hid2 = gid ()
      hid3 = gid ()
      parseAst v =
        case v of
          "if" ->
            Just (If eid (Thread tid1 [Hole hid1]) (Thread tid2 [Hole hid2]) (Thread tid3 [Hole hid3]))
          "let" ->
              Just (Let eid [(BindHole hid1, Thread tid1 [Hole hid2])] (Thread tid2 [Hole hid3]))
          "lambda" ->
            Just (Lambda eid ["var"] (Thread tid1 [Hole hid1]))
          str ->
            if RT.tipeOf str == TIncomplete || AST.isInfix str
            -- TODO: create Threads here also -- and perhaps one fewer hole if we're the RHS of a thread already?
            then createFunction m value
            else Just <| Value eid str

  in
  case cursor of
    Creating pos ->
      let sample = {name = "/new", module_ = "HTTP", modifiers = ["POST"]} in
      case parseAst value of
        Nothing -> NoChange
        Just v -> RPC ([SetTL id pos v (Just sample)], FocusNext id)
    Filling tlid id ->
      let tl = TL.getTL m tlid
      in
          if TL.isBindHole m tlid id
          then
            RPC ([SetTL tl.id tl.pos (AST.replaceBindHole id value tl.ast) tl.handlerSpec]
            , FocusNext tl.id)
          else
            -- check if value is in model.varnames
            let (ID rid) = id
                availableVars =
                  let avd = Analysis.getAvailableVarnames m tlid
                  in (Dict.get rid avd) |> (Maybe.withDefault [])
                holeReplacement =
                  if List.member value availableVars
                  then Just (Variable (gid ()) value)
                  else parseAst value
            in
            case holeReplacement of
              Nothing -> NoChange
              Just v -> RPC ([SetTL tl.id tl.pos (AST.replaceHole id v tl.ast) tl.handlerSpec]
              , FocusNext tl.id)

  -- let pt = EntryParser.parseFully value
  -- in case pt of
  --   Ok pt -> execute m re <| EntryParser.pt2ast m cursor pt
  --   Err error -> Error <| EntryParser.toErrorMessage <| EntryParser.addCursorToError error cursor
