(* open Webapi.Dom *)
open Tc
open Types
open Prelude
module K = FluidKeyboard
module Mouse = Tea.Mouse
module Regex = Util.Regex
module TL = Toplevel

(* Tea *)
module Cmd = Tea.Cmd

module Html = struct
  include Tea.Html

  type 'a html = 'a Vdom.t
end

module Attrs = Tea.Html2.Attributes
module Events = Tea.Html2.Events
module AC = FluidAutocomplete
module Token = FluidToken

(* -------------------- *)
(* Utils *)
(* -------------------- *)

let removeCharAt str offset : string =
  if offset < 0
  then str
  else
    String.slice ~from:0 ~to_:offset str
    ^ String.slice ~from:(offset + 1) ~to_:(String.length str) str


let isNumber (str : string) = Js.Re.test_ [%re "/[0-9]+/"] str

let isIdentifierChar (str : string) = Js.Re.test_ [%re "/[_a-zA-Z0-9]+/"] str

let isFnNameChar str =
  Js.Re.test_ [%re "/[_:a-zA-Z0-9]/"] str && String.length str = 1


let safe_int_of_string (s : string) : int =
  (* 2,147,483,647 *)
  try String.left ~count:10 s |> int_of_string with _ ->
    String.left ~count:9 s |> int_of_string


exception FExc of string

let fail str = raise (FExc str)

(* -------------------- *)
(* Expressions *)
(* -------------------- *)

type ast = fluidExpr [@@deriving show]

type state = Types.fluidState

let rec fromExpr (s : state) (expr : Types.expr) : fluidExpr =
  let varToName var = match var with Blank _ -> "" | F (_, name) -> name in
  let parseString str :
      [> `Bool of bool
      | `Int of int
      | `Null
      | `Float of string * string
      | `Unknown ] =
    let asBool =
      if str = "true"
      then Some (`Bool true)
      else if str = "false"
      then Some (`Bool false)
      else if str = "null"
      then Some `Null
      else None
    in
    let asInt = try Some (`Int (int_of_string str)) with _ -> None in
    let asFloat =
      try
        (* for the exception *)
        ignore (float_of_string str) ;
        match String.split ~on:"." str with
        | [whole; fraction] ->
            Some (`Float (whole, fraction))
        | _ ->
            None
      with _ -> None
    in
    let asString =
      if String.startsWith ~prefix:"\"" str && String.endsWith ~suffix:"\"" str
      then
        Some
          (`String
            (str |> String.dropLeft ~count:1 |> String.dropRight ~count:1))
      else None
    in
    asInt
    |> Option.or_ asString
    |> Option.or_ asBool
    |> Option.or_ asFloat
    |> Option.withDefault ~default:`Unknown
  in
  let fromExpr = fromExpr s in
  match expr with
  | Blank id ->
      EBlank id
  | F (id, nExpr) ->
    ( match nExpr with
    | Let (name, rhs, body) ->
        ELet (id, Blank.toID name, varToName name, fromExpr rhs, fromExpr body)
    | Variable varname ->
        EVariable (id, varname)
    | If (cond, thenExpr, elseExpr) ->
        EIf (id, fromExpr cond, fromExpr thenExpr, fromExpr elseExpr)
    | ListLiteral exprs ->
        EList (id, List.map ~f:fromExpr exprs)
    | ObjectLiteral pairs ->
        ERecord
          ( id
          , List.map pairs ~f:(fun (k, v) ->
                (Blank.toID k, varToName k, fromExpr v) ) )
    | FieldAccess (expr, field) ->
        EFieldAccess (id, fromExpr expr, Blank.toID field, varToName field)
    | FnCall (name, args, ster) ->
        let args = List.map ~f:fromExpr args in
        let fnCall = EFnCall (id, varToName name, args, ster) in
        let fn =
          List.find s.ac.functions ~f:(fun fn -> fn.fnName = varToName name)
        in
        ( match fn with
        | Some fn when fn.fnInfix ->
          ( match args with
          | [a; b] ->
              EBinOp (id, varToName name, a, b, ster)
          | _ ->
              fnCall )
        | _ ->
            fnCall )
    | Thread exprs ->
        EThread (id, List.map ~f:fromExpr exprs)
    | Lambda (varnames, exprs) ->
        ELambda
          ( id
          , List.map varnames ~f:(fun var -> (Blank.toID var, varToName var))
          , fromExpr exprs )
    | Value str ->
      ( match parseString str with
      | `Bool b ->
          EBool (id, b)
      | `Int i ->
          EInteger (id, i)
      | `String s ->
          EString (id, s)
      | `Null ->
          ENull id
      | `Float (whole, fraction) ->
          EFloat (id, whole, fraction)
      | `Unknown ->
          Js.log2 "Getting old Value that we coudln't parse" expr ;
          EOldExpr expr )
    | Constructor (name, exprs) ->
        EConstructor
          (id, Blank.toID name, varToName name, List.map ~f:fromExpr exprs)
    | Match (mexpr, pairs) ->
        let mid = id in
        let rec fromPattern (p : pattern) : fluidPattern =
          match p with
          | Blank id ->
              FPBlank (mid, id)
          | F (id, np) ->
            ( match np with
            | PVariable name ->
                FPVariable (mid, id, name)
            | PConstructor (name, patterns) ->
                FPConstructor (mid, id, name, List.map ~f:fromPattern patterns)
            | PLiteral str ->
              ( match parseString str with
              | `Bool b ->
                  FPBool (mid, id, b)
              | `Int i ->
                  FPInteger (mid, id, i)
              | `String s ->
                  FPString (mid, id, s)
              | `Null ->
                  FPNull (mid, id)
              | `Float (whole, fraction) ->
                  FPFloat (mid, id, whole, fraction)
              | `Unknown ->
                  Js.log2
                    "Getting old pattern literal that we couldn't parse"
                    p ;
                  FPOldPattern (mid, p) ) )
        in
        let pairs =
          List.map pairs ~f:(fun (p, e) -> (fromPattern p, fromExpr e))
        in
        EMatch (id, fromExpr mexpr, pairs)
    | FeatureFlag _ ->
        EOldExpr expr
    | FluidPartial (str, oldExpr) ->
        EPartial (id, str, fromExpr oldExpr)
    | FluidRightPartial (str, oldExpr) ->
        ERightPartial (id, str, fromExpr oldExpr) )


let literalToString
    (v : [> `Bool of bool | `Int of int | `Null | `Float of string * string]) :
    string =
  match v with
  | `Int i ->
      Int.toString i
  | `String str ->
      "\"" ^ str ^ "\""
  | `Bool b ->
      if b then "true" else "false"
  | `Null ->
      "null"
  | `Float (whole, fraction) ->
      whole ^ "." ^ fraction


let rec toPattern (p : fluidPattern) : pattern =
  match p with
  | FPVariable (_, id, var) ->
      F (id, PVariable var)
  | FPConstructor (_, id, name, patterns) ->
      F (id, PConstructor (name, List.map ~f:toPattern patterns))
  | FPInteger (_, id, i) ->
      F (id, PLiteral (literalToString (`Int i)))
  | FPBool (_, id, b) ->
      F (id, PLiteral (literalToString (`Bool b)))
  | FPString (_, id, str) ->
      F (id, PLiteral (literalToString (`String str)))
  | FPFloat (_, id, whole, fraction) ->
      F (id, PLiteral (literalToString (`Float (whole, fraction))))
  | FPNull (_, id) ->
      F (id, PLiteral (literalToString `Null))
  | FPBlank (_, id) ->
      Blank id
  | FPOldPattern (_, pattern) ->
      pattern


let rec toExpr (expr : fluidExpr) : Types.expr =
  (* TODO: remove any new generation (gid ()) from this fn, save the old
   * ones instead *)
  match expr with
  | EInteger (id, num) ->
      F (id, Value (literalToString (`Int num)))
  | EString (id, str) ->
      F (id, Value (literalToString (`String str)))
  | EFloat (id, whole, fraction) ->
      F (id, Value (literalToString (`Float (whole, fraction))))
  | EBool (id, b) ->
      F (id, Value (literalToString (`Bool b)))
  | ENull id ->
      F (id, Value (literalToString `Null))
  | EVariable (id, var) ->
      F (id, Variable var)
  | EFieldAccess (id, obj, fieldID, fieldname) ->
      F (id, FieldAccess (toExpr obj, F (fieldID, fieldname)))
  | EFnCall (id, name, args, ster) ->
      F
        ( id
        , FnCall
            (F (ID (deID id ^ "_name"), name), List.map ~f:toExpr args, ster)
        )
  | EBinOp (id, name, arg1, arg2, ster) ->
      F
        ( id
        , FnCall
            (F (ID (deID id ^ "_name"), name), [toExpr arg1; toExpr arg2], ster)
        )
  | ELambda (id, vars, body) ->
      F
        ( id
        , Lambda
            ( List.map vars ~f:(fun (vid, var) -> Types.F (vid, var))
            , toExpr body ) )
  | EBlank id ->
      Blank id
  | ELet (id, lhsID, lhs, rhs, body) ->
      F (id, Let (F (lhsID, lhs), toExpr rhs, toExpr body))
  | EIf (id, cond, thenExpr, elseExpr) ->
      F (id, If (toExpr cond, toExpr thenExpr, toExpr elseExpr))
  | EPartial (id, str, oldVal) ->
      F (id, FluidPartial (str, toExpr oldVal))
  | ERightPartial (id, str, oldVal) ->
      F (id, FluidRightPartial (str, toExpr oldVal))
  | EList (id, exprs) ->
      F (id, ListLiteral (List.map ~f:toExpr exprs))
  | ERecord (id, pairs) ->
      F
        ( id
        , ObjectLiteral
            (List.map pairs ~f:(fun (id, k, v) -> (Types.F (id, k), toExpr v)))
        )
  | EThread (id, exprs) ->
      F (id, Thread (List.map ~f:toExpr exprs))
  | EConstructor (id, nameID, name, exprs) ->
      F (id, Constructor (F (nameID, name), List.map ~f:toExpr exprs))
  | EMatch (id, mexpr, pairs) ->
      let pairs = List.map pairs ~f:(fun (p, e) -> (toPattern p, toExpr e)) in
      F (id, Match (toExpr mexpr, pairs))
  | EOldExpr expr ->
      expr


let eid expr : id =
  match expr with
  | EOldExpr expr ->
      Blank.toID expr
  | EInteger (id, _)
  | EString (id, _)
  | EBool (id, _)
  | ENull id
  | EFloat (id, _, _)
  | EVariable (id, _)
  | EFieldAccess (id, _, _, _)
  | EFnCall (id, _, _, _)
  | ELambda (id, _, _)
  | EBlank id
  | ELet (id, _, _, _, _)
  | EIf (id, _, _, _)
  | EPartial (id, _, _)
  | ERightPartial (id, _, _)
  | EList (id, _)
  | ERecord (id, _)
  | EThread (id, _)
  | EBinOp (id, _, _, _, _)
  | EConstructor (id, _, _, _)
  | EMatch (id, _, _) ->
      id


let pid pattern : id =
  match pattern with
  | FPVariable (_, id, _)
  | FPConstructor (_, id, _, _)
  | FPInteger (_, id, _)
  | FPBool (_, id, _)
  | FPString (_, id, _)
  | FPFloat (_, id, _, _)
  | FPNull (_, id)
  | FPBlank (_, id) ->
      id
  | FPOldPattern (_, pattern) ->
      Blank.toID pattern


let pmid pattern : id =
  match pattern with
  | FPVariable (mid, _, _)
  | FPConstructor (mid, _, _, _)
  | FPInteger (mid, _, _)
  | FPBool (mid, _, _)
  | FPString (mid, _, _)
  | FPFloat (mid, _, _, _)
  | FPNull (mid, _)
  | FPBlank (mid, _) ->
      mid
  | FPOldPattern (mid, _) ->
      mid


let newB () = EBlank (gid ())

(* -------------------- *)
(* Tokens *)
(* -------------------- *)
type token = Types.fluidToken

type tokenInfo = Types.fluidTokenInfo

let rec patternToToken (p : fluidPattern) : fluidToken list =
  match p with
  | FPVariable (mid, id, name) ->
      [TPatternVariable (mid, id, name)]
  | FPConstructor (mid, id, name, args) ->
      let args = List.map args ~f:(fun a -> TSep :: patternToToken a) in
      List.concat ([TPatternConstructorName (mid, id, name)] :: args)
  | FPInteger (mid, id, i) ->
      [TPatternInteger (mid, id, string_of_int i)]
  | FPBool (mid, id, b) ->
      if b then [TPatternTrue (mid, id)] else [TPatternFalse (mid, id)]
  | FPString (mid, id, s) ->
      [TPatternString (mid, id, s)]
  | FPFloat (mID, id, whole, fraction) ->
      let whole =
        if whole = "" then [] else [TPatternFloatWhole (mID, id, whole)]
      in
      let fraction =
        if fraction = ""
        then []
        else [TPatternFloatFraction (mID, id, fraction)]
      in
      whole @ [TPatternFloatPoint (mID, id)] @ fraction
  | FPNull (mid, id) ->
      [TPatternNullToken (mid, id)]
  | FPBlank (mid, id) ->
      [TPatternBlank (mid, id)]
  | FPOldPattern (mid, op) ->
      [TPatternString (mid, Blank.toID op, "TODO: old pattern")]


let rec toTokens' (s : state) (e : ast) : token list =
  let nested ?(placeholderFor : (string * int) option = None) b =
    let tokens =
      match (b, placeholderFor) with
      | EBlank id, Some (fnname, pos) ->
          let name =
            s.ac.functions
            |> List.find ~f:(fun f -> f.fnName = fnname)
            |> Option.andThen ~f:(fun fn ->
                   List.getAt ~index:pos fn.fnParameters )
            |> Option.map ~f:(fun p ->
                   (p.paramName, Runtime.tipe2str p.paramTipe) )
          in
          ( match name with
          | None ->
              toTokens' s b
          | Some placeholder ->
              [TPlaceholder (placeholder, id)] )
      | _ ->
          toTokens' s b
    in
    TIndentToHere tokens
  in
  match e with
  | EInteger (id, i) ->
      [TInteger (id, string_of_int i)]
  | EBool (id, b) ->
      if b then [TTrue id] else [TFalse id]
  | ENull id ->
      [TNullToken id]
  | EFloat (id, whole, fraction) ->
      let whole = if whole = "" then [] else [TFloatWhole (id, whole)] in
      let fraction =
        if fraction = "" then [] else [TFloatFraction (id, fraction)]
      in
      whole @ [TFloatPoint id] @ fraction
  | EBlank id ->
      [TBlank id]
  | ELet (id, _, lhs, rhs, next) ->
      [ TLetKeyword id
      ; TLetLHS (id, lhs)
      ; TLetAssignment id
      ; nested rhs
      ; TNewline
      ; nested next ]
  | EString (id, str) ->
      [TString (id, str)]
  | EIf (id, cond, if', else') ->
      [ TIfKeyword id
      ; nested cond
      ; TNewline
      ; TIfThenKeyword id
      ; TNewline
      ; TIndent 2
      ; nested if'
      ; TNewline
      ; TIfElseKeyword id
      ; TNewline
      ; TIndent 2
      ; nested else' ]
  | EBinOp (id, op, lexpr, rexpr, _ster) ->
      [ nested ~placeholderFor:(Some (op, 0)) lexpr
      ; TSep
      ; TBinOp (id, op)
      ; TSep
      ; nested ~placeholderFor:(Some (op, 1)) rexpr ]
  | EPartial (id, newOp, EBinOp (_, op, lexpr, rexpr, _ster)) ->
      let ghostSuffix = String.dropLeft ~count:(String.length newOp) op in
      let ghost =
        if ghostSuffix = "" then [] else [TPartialGhost (id, ghostSuffix)]
      in
      [nested ~placeholderFor:(Some (op, 0)) lexpr; TSep; TPartial (id, newOp)]
      @ ghost
      @ [TSep; nested ~placeholderFor:(Some (op, 1)) rexpr]
  | EFieldAccess (id, expr, fieldID, fieldname) ->
      [nested expr; TFieldOp id; TFieldName (id, fieldID, fieldname)]
  | EVariable (id, name) ->
      [TVariable (id, name)]
  | ELambda (id, names, body) ->
      let tnames =
        List.indexedMap names ~f:(fun i (_, name) -> TLambdaVar (id, i, name))
        |> List.intersperse (TLambdaSep id)
      in
      [TLambdaSymbol id] @ tnames @ [TLambdaArrow id; nested body]
  | EFnCall (id, fnName, exprs, ster) ->
      [TFnName (id, fnName, ster)]
      @ ( exprs
        |> List.indexedMap ~f:(fun i e ->
               [TSep; nested ~placeholderFor:(Some (fnName, i)) e] )
        |> List.concat )
  | EList (id, exprs) ->
      let ts =
        exprs
        |> List.map ~f:(fun expr -> [nested expr; TListSep id])
        |> List.concat
        (* Remove the extra seperator *)
        |> List.dropRight ~count:1
      in
      [TListOpen id] @ ts @ [TListClose id]
  | ERecord (id, fields) ->
      if fields = []
      then [TRecordOpen id; TRecordClose id]
      else
        [ [TRecordOpen id]
        ; List.mapi fields ~f:(fun i (_, fname, expr) ->
              [ TNewline
              ; TIndentToHere
                  [ TIndent 2
                  ; TRecordField (id, i, fname)
                  ; TSep
                  ; TRecordSep (id, i)
                  ; TSep
                  ; nested expr ] ] )
          |> List.concat
        ; [TNewline; TRecordClose id] ]
        |> List.concat
  | EThread (id, exprs) ->
    ( match exprs with
    | [] ->
        Js.log2 "Empty thread found" (show_fluidExpr e) ;
        []
    | [single] ->
        Js.log2 "Thread with single entry found" (show_fluidExpr single) ;
        [nested single]
    | head :: tail ->
        [ nested head
        ; TNewline
        ; TIndentToHere
            ( tail
            |> List.indexedMap ~f:(fun i e ->
                   let thread =
                     [TIndentToHere [TThreadPipe (id, i); nested e]]
                   in
                   if i == 0 then thread else TNewline :: thread )
            |> List.concat ) ] )
  | EConstructor (id, _, name, exprs) ->
      [TConstructorName (id, name)]
      @ (exprs |> List.map ~f:(fun e -> [TSep; nested e]) |> List.concat)
  | EMatch (id, mexpr, pairs) ->
      [ [TMatchKeyword id; nested mexpr]
      ; List.map pairs ~f:(fun (pattern, expr) ->
            [TNewline; TIndent 2]
            @ patternToToken pattern
            @ [TSep; TMatchSep (pid pattern); TSep; nested expr] )
        |> List.concat ]
      |> List.concat
  | EOldExpr expr ->
      [TPartial (Blank.toID expr, "TODO: oldExpr")]
  | EPartial (id, str, _) ->
      [TPartial (id, str)]
  | ERightPartial (id, newOp, expr) ->
      [nested expr; TSep; TRightPartial (id, newOp)]


(* TODO: we need some sort of reflow thing that handles line length. *)
let rec reflow ~(x : int) (startingTokens : token list) : int * token list =
  let startingX = x in
  List.foldl startingTokens ~init:(x, []) ~f:(fun t (x, old) ->
      let text = Token.toText t in
      let len = String.length text in
      match t with
      | TIndented tokens ->
          let newX, newTokens = reflow ~x:(x + 2) tokens in
          (newX, old @ [TIndent (startingX + 2)] @ newTokens)
      | TIndentToHere tokens ->
          let newX, newTokens = reflow ~x tokens in
          (newX, old @ newTokens)
      | TNewline ->
          if startingX = 0
          then (startingX, old @ [t])
          else (startingX, old @ [t; TIndent startingX])
      | _ ->
          (x + len, old @ [t]) )


let infoize ~(pos : int) tokens : tokenInfo list =
  let row, col = (ref 0, ref 0) in
  let rec makeInfo p ts =
    match ts with
    | [] ->
        []
    | token :: rest ->
        let length = String.length (Token.toText token) in
        let ti =
          { token
          ; startRow = !row
          ; startCol = !col
          ; startPos = p
          ; endPos = p + length
          ; length }
        in
        ( match token with
        | TNewline ->
            row := !row + 1 ;
            col := 0
        | _ ->
            col := !col + length ) ;
        ti :: makeInfo (p + length) rest
  in
  makeInfo pos tokens


let validateTokens (tokens : fluidToken list) : fluidToken list =
  List.iter
    ~f:(fun t ->
      if String.length (Token.toText t) == 0
      then impossible "zero length token"
      else () )
    tokens ;
  tokens


let toTokens (s : state) (e : ast) : tokenInfo list =
  e
  |> toTokens' s
  |> validateTokens
  |> reflow ~x:0
  |> Tuple2.second
  |> infoize ~pos:0


let eToString (s : state) (e : ast) : string =
  e
  |> toTokens s
  |> List.map ~f:(fun ti -> Token.toTestText ti.token)
  |> String.join ~sep:""


let eToStructure (s : state) (e : fluidExpr) : string =
  e
  |> toTokens s
  |> List.map ~f:(fun ti ->
         "<" ^ Token.toTypeName ti.token ^ ":" ^ Token.toText ti.token ^ ">" )
  |> String.join ~sep:""


(* -------------------- *)
(* Patterns *)
(* -------------------- *)
let pToString (p : fluidPattern) : string =
  p
  |> patternToToken
  |> List.map ~f:(fun t -> Token.toTestText t)
  |> String.join ~sep:""


(* -------------------- *)
(* Direct canvas interaction *)
(* -------------------- *)

let editorID = "fluid-editor"

(* -------------------- *)
(* Update fluid state *)
(* -------------------- *)
let tiSentinel : tokenInfo =
  { token = TSep
  ; startPos = -1000
  ; startRow = -1000
  ; startCol = -1000
  ; endPos = -1000
  ; length = -1000 }


let recordAction
    ?(pos = -1000) ?(ti = tiSentinel) (action : string) (s : state) : state =
  let action =
    if pos = -1000 then action else action ^ " " ^ string_of_int pos
  in
  let action =
    if ti = tiSentinel then action else action ^ " " ^ show_fluidToken ti.token
  in
  {s with actions = s.actions @ [action]}


let setPosition ?(resetUD = false) (s : state) (pos : int) : state =
  let s = recordAction ~pos "setPosition" s in
  let upDownCol = if resetUD then None else s.upDownCol in
  {s with newPos = pos; upDownCol}


let report (e : string) (s : state) =
  let s = recordAction "report" s in
  {s with error = Some e}


(* -------------------- *)
(* Update *)
(* -------------------- *)

let length (tokens : token list) : int =
  tokens |> List.map ~f:Token.toText |> List.map ~f:String.length |> List.sum


(* Returns the token to the left and to the right. Ignores indent tokens *)

let getLeftTokenAt (newPos : int) (tis : tokenInfo list) : tokenInfo option =
  List.find ~f:(fun ti -> newPos <= ti.endPos && newPos >= ti.startPos) tis


type neighbour =
  | L of token * tokenInfo
  | R of token * tokenInfo
  | No

let rec getTokensAtPosition
    ?(prev = None) ~(pos : int) (tokens : tokenInfo list) :
    tokenInfo option * tokenInfo option * tokenInfo option =
  (* Get the next token and the remaining tokens, skipping indents. *)
  let rec getNextToken (infos : tokenInfo list) :
      tokenInfo option * tokenInfo list =
    match infos with
    | ti :: rest ->
        if Token.isSkippable ti.token
        then getNextToken rest
        else (Some ti, rest)
    | [] ->
        (None, [])
  in
  match getNextToken tokens with
  | None, _remaining ->
      (prev, None, None)
  | Some current, remaining ->
      if current.endPos > pos
      then
        let next, _ = getNextToken remaining in
        (prev, Some current, next)
      else getTokensAtPosition ~prev:(Some current) ~pos remaining


let getNeighbours ~(pos : int) (tokens : tokenInfo list) :
    neighbour * neighbour * tokenInfo option =
  let mPrev, mCurrent, mNext = getTokensAtPosition ~pos tokens in
  let toTheRight =
    match mCurrent with Some current -> R (current.token, current) | _ -> No
  in
  (* The token directly before the cursor (skipping whitespace) *)
  let toTheLeft =
    match (mPrev, mCurrent) with
    | Some prev, _ when prev.endPos >= pos ->
        L (prev.token, prev)
    (* The left might be separated by whitespace *)
    | Some prev, Some current when current.startPos >= pos ->
        L (prev.token, prev)
    | _, Some current ->
        L (current.token, current)
    | Some prev, None ->
        (* Last position in the ast *)
        L (prev.token, prev)
    | None, None ->
        No
  in
  (toTheLeft, toTheRight, mNext)


type gridPos =
  { row : int
  ; col : int }

(* Result will definitely be a valid position. *)
let gridFor ~(pos : int) (tokens : tokenInfo list) : gridPos =
  let ti =
    List.find tokens ~f:(fun ti -> ti.startPos <= pos && ti.endPos >= pos)
  in
  match ti with
  | Some ti ->
      if ti.token = TNewline
      then {row = ti.startRow + 1; col = 0}
      else {row = ti.startRow; col = ti.startCol + (pos - ti.startPos)}
  | None ->
      {row = 0; col = 0}


(* Result will definitely be a valid position. *)
let posFor ~(row : int) ~(col : int) (tokens : tokenInfo list) : int =
  if row < 0 || col < 0
  then 0
  else
    let ti =
      List.find tokens ~f:(fun ti ->
          ti.startRow = row
          && ti.startCol <= col
          && ti.startCol + ti.length >= col )
    in
    match ti with
    | Some ti ->
        ti.startPos + (col - ti.startCol)
    | None ->
      (match List.last tokens with None -> 0 | Some last -> last.endPos)


(* Ensures that the position places will be valid within the code. When placed
 * in an indent, will be moved to the next char. Empty lines get moved to the
 * start. When placed past the end of a line, will go on the end of the last
 * item in it. *)
let adjustedPosFor ~(row : int) ~(col : int) (tokens : tokenInfo list) : int =
  if row < 0 || col < 0
  then 0
  else
    let thisRow = List.filter tokens ~f:(fun ti -> ti.startRow = row) in
    let ti =
      List.find thisRow ~f:(fun ti ->
          ti.startCol <= col && ti.startCol + ti.length > col )
    in
    match ti with
    | Some ti ->
        ti.startPos + (col - ti.startCol)
    | None ->
      ( match (List.head thisRow, List.last thisRow) with
      | Some h, _ when col < h.startCol ->
          h.startPos
      | _, Some l when col >= l.startCol ->
        ( match l.token with
        | TNewline ->
            l.startPos
        | _ ->
            l.startPos + l.length )
      | None, None ->
          posFor ~row ~col:0 tokens
      | _, _ ->
          fail "adjustedPosFor" )


(* ------------- *)
(* Getting expressions *)
(* ------------- *)
let rec findExpr (id : id) (expr : fluidExpr) : fluidExpr option =
  let fe = findExpr id in
  if eid expr = id
  then Some expr
  else
    match expr with
    | EInteger _
    | EBlank _
    | EString _
    | EVariable _
    | EBool _
    | ENull _
    | EFloat _ ->
        None
    | ELet (_, _, _, rhs, next) ->
        fe rhs |> Option.orElse (fe next)
    | EIf (_, cond, ifexpr, elseexpr) ->
        fe cond |> Option.orElse (fe ifexpr) |> Option.orElse (fe elseexpr)
    | EBinOp (_, _, lexpr, rexpr, _) ->
        fe lexpr |> Option.orElse (fe rexpr)
    | EFieldAccess (_, expr, _, _) | ELambda (_, _, expr) ->
        fe expr
    | ERecord (_, fields) ->
        fields |> List.map ~f:Tuple3.third |> List.filterMap ~f:fe |> List.head
    | EMatch (_, _, pairs) ->
        pairs |> List.map ~f:Tuple2.second |> List.filterMap ~f:fe |> List.head
    | EFnCall (_, _, exprs, _)
    | EList (_, exprs)
    | EConstructor (_, _, _, exprs)
    | EThread (_, exprs) ->
        List.filterMap ~f:fe exprs |> List.head
    | EOldExpr _ ->
        None
    | EPartial (_, _, oldExpr) | ERightPartial (_, _, oldExpr) ->
        fe oldExpr


let isEmpty (e : fluidExpr) : bool =
  let isBlank e = match e with EBlank _ -> true | _ -> false in
  match e with
  | EBlank _ ->
      true
  | ERecord (_, []) ->
      true
  | ERecord (_, l) ->
      l
      |> List.filter ~f:(fun (_, k, v) -> k = "" && not (isBlank v))
      |> List.isEmpty
  | EList (_, l) ->
      l |> List.filter ~f:(not << isBlank) |> List.isEmpty
  | _ ->
      false


let exprIsEmpty (id : id) (ast : ast) : bool =
  match findExpr id ast with Some e -> isEmpty e | _ -> false


let findParent (id : id) (ast : ast) : fluidExpr option =
  let rec findParent' ~(parent : fluidExpr option) (id : id) (expr : fluidExpr)
      : fluidExpr option =
    let fp = findParent' ~parent:(Some expr) id in
    if eid expr = id
    then parent
    else
      match expr with
      | EInteger _
      | EBlank _
      | EString _
      | EVariable _
      | EBool _
      | ENull _
      | EFloat _ ->
          None
      | ELet (_, _, _, rhs, next) ->
          fp rhs |> Option.orElse (fp next)
      | EIf (_, cond, ifexpr, elseexpr) ->
          fp cond |> Option.orElse (fp ifexpr) |> Option.orElse (fp elseexpr)
      | EBinOp (_, _, lexpr, rexpr, _) ->
          fp lexpr |> Option.orElse (fp rexpr)
      | EFieldAccess (_, expr, _, _) | ELambda (_, _, expr) ->
          fp expr
      | EMatch (_, _, pairs) ->
          pairs
          |> List.map ~f:Tuple2.second
          |> List.filterMap ~f:fp
          |> List.head
      | ERecord (_, fields) ->
          fields
          |> List.map ~f:Tuple3.third
          |> List.filterMap ~f:fp
          |> List.head
      | EFnCall (_, _, exprs, _)
      | EList (_, exprs)
      | EConstructor (_, _, _, exprs)
      | EThread (_, exprs) ->
          List.filterMap ~f:fp exprs |> List.head
      | EOldExpr _ ->
          None
      | EPartial (_, _, expr) ->
          fp expr
      | ERightPartial (_, _, expr) ->
          fp expr
  in
  findParent' ~parent:None id ast


(* ------------- *)
(* Replacing expressions *)
(* ------------- *)
(* f needs to call recurse or it won't go far *)
let recurse ~(f : fluidExpr -> fluidExpr) (expr : fluidExpr) : fluidExpr =
  match expr with
  | EInteger _
  | EBlank _
  | EString _
  | EVariable _
  | EBool _
  | ENull _
  | EFloat _ ->
      expr
  | ELet (id, lhsID, name, rhs, next) ->
      ELet (id, lhsID, name, f rhs, f next)
  | EIf (id, cond, ifexpr, elseexpr) ->
      EIf (id, f cond, f ifexpr, f elseexpr)
  | EBinOp (id, op, lexpr, rexpr, ster) ->
      EBinOp (id, op, f lexpr, f rexpr, ster)
  | EFieldAccess (id, expr, fieldID, fieldname) ->
      EFieldAccess (id, f expr, fieldID, fieldname)
  | EFnCall (id, name, exprs, ster) ->
      EFnCall (id, name, List.map ~f exprs, ster)
  | ELambda (id, names, expr) ->
      ELambda (id, names, f expr)
  | EList (id, exprs) ->
      EList (id, List.map ~f exprs)
  | EMatch (id, mexpr, pairs) ->
      EMatch
        (id, f mexpr, List.map ~f:(fun (name, expr) -> (name, f expr)) pairs)
  | ERecord (id, fields) ->
      ERecord
        (id, List.map ~f:(fun (id, name, expr) -> (id, name, f expr)) fields)
  | EThread (id, exprs) ->
      EThread (id, List.map ~f exprs)
  | EConstructor (id, nameID, name, exprs) ->
      EConstructor (id, nameID, name, List.map ~f exprs)
  | EOldExpr _ ->
      expr
  | EPartial (id, str, oldExpr) ->
      EPartial (id, str, f oldExpr)
  | ERightPartial (id, str, oldExpr) ->
      ERightPartial (id, str, f oldExpr)


(* Slightly modified version of `AST.uses` (pre-fluid code) *)
let rec modifyVariableOccurences
    (oldVarName : string) (newVarName : string) (ast : ast) : ast =
  let u = modifyVariableOccurences oldVarName newVarName in
  match ast with
  | EVariable (id, varName) ->
      if varName = oldVarName then EVariable (id, newVarName) else ast
  | ELet (id, id', lhs, rhs, body) ->
      if oldVarName = lhs (* if variable name is rebound *)
      then ast
      else ELet (id, id', lhs, u rhs, u body)
  | ELambda (id, vars, lexpr) ->
      if List.map ~f:Tuple2.second vars |> List.member ~value:oldVarName
         (* if variable name is rebound *)
      then ast
      else ELambda (id, vars, u lexpr)
  | EMatch (id, cond, pairs) ->
      let pairs =
        List.map
          ~f:(fun (pat, expr) ->
            if Pattern.hasVariableNamed oldVarName (toPattern pat)
            then (pat, expr)
            else (pat, u expr) )
          pairs
      in
      EMatch (id, u cond, pairs)
  | _ ->
      recurse ~f:u ast


let wrap ~(f : fluidExpr -> fluidExpr) (id : id) (ast : ast) : ast =
  let rec run e = if id = eid e then f e else recurse ~f:run e in
  run ast


let replaceExpr ~(newExpr : fluidExpr) (id : id) (ast : ast) : ast =
  wrap id ast ~f:(fun _ -> newExpr)


let wrapPattern
    ~(f : fluidPattern -> fluidPattern) (matchID : id) (patID : id) (ast : ast)
    : ast =
  wrap matchID ast ~f:(fun m ->
      match m with
      | EMatch (matchID, expr, pairs) ->
          let newPairs =
            List.map pairs ~f:(fun (pat, expr) ->
                if pid pat = patID then (f pat, expr) else (pat, expr) )
          in
          EMatch (matchID, expr, newPairs)
      | _ ->
          m )


let replacePattern
    ~(newPat : fluidPattern) (matchID : id) (patID : id) (ast : ast) : ast =
  wrapPattern matchID patID ast ~f:(fun _ -> newPat)


let replaceVarInPattern
    (mID : id) (oldVarName : string) (newVarName : string) (ast : ast) : ast =
  wrap mID ast ~f:(fun e ->
      match e with
      | EMatch (mID, cond, cases) ->
          let rec replaceNameInPattern pat =
            match pat with
            | FPVariable (_, id, varName) when varName = oldVarName ->
                if newVarName = ""
                then FPBlank (mID, id)
                else FPVariable (mID, id, newVarName)
            | FPConstructor (mID, id, name, patterns) ->
                FPConstructor
                  (mID, id, name, List.map patterns ~f:replaceNameInPattern)
            | pattern ->
                pattern
          in
          let newCases =
            List.map cases ~f:(fun (pat, expr) ->
                ( replaceNameInPattern pat
                , modifyVariableOccurences oldVarName newVarName expr ) )
          in
          EMatch (mID, cond, newCases)
      | _ ->
          fail "not a let" )


let removeField (id : id) (ast : ast) : ast =
  wrap id ast ~f:(fun e ->
      match e with
      | EFieldAccess (_, faExpr, _, _) ->
          faExpr
      | _ ->
          fail "not a fieldAccess" )


let deleteWithArguments (id : id) (ast : ast) : ast =
  wrap id ast ~f:(fun e ->
      match e with
      | EFnCall (_, _, _, _) ->
          EBlank (gid ())
      | EBinOp (_, _, _, _, _) ->
          EBlank (gid ())
      | EConstructor (_, _, _, _) ->
          EBlank (gid ())
      | _ ->
          fail "not a fncall " )


let removeRecordField (id : id) (index : int) (ast : ast) : ast =
  wrap id ast ~f:(fun e ->
      match e with
      | ERecord (id, fields) ->
          ERecord (id, List.removeAt ~index fields)
      | _ ->
          fail "not a record field" )


let exprToFieldAccess (id : id) (ast : ast) : ast =
  wrap id ast ~f:(fun e -> EFieldAccess (gid (), e, gid (), ""))


let removeEmptyExpr (id : id) (ast : ast) : ast =
  wrap id ast ~f:(fun e ->
      match e with
      | ELet (_, _, "", EBlank _, body) ->
          body
      | EIf (_, EBlank _, EBlank _, EBlank _) ->
          newB ()
      | ELambda (_, _, EBlank _) ->
          newB ()
      | EMatch (_, EBlank _, pairs)
        when List.all pairs ~f:(fun (p, e) ->
                 match (p, e) with FPBlank _, EBlank _ -> true | _ -> false )
        ->
          newB ()
      | _ ->
          e )


let replaceFieldName (str : string) (id : id) (ast : ast) : ast =
  wrap id ast ~f:(fun e ->
      match e with
      | EFieldAccess (id, expr, fieldID, _) ->
          EFieldAccess (id, expr, fieldID, str)
      | _ ->
          fail "not a field" )


let replaceLamdaVar
    ~(index : int)
    (oldVarName : string)
    (newVarName : string)
    (id : id)
    (ast : ast) : ast =
  wrap id ast ~f:(fun e ->
      match e with
      | ELambda (id, vars, expr) ->
          let vars =
            List.updateAt vars ~index ~f:(fun (id, _) -> (id, newVarName))
          in
          ELambda
            (id, vars, modifyVariableOccurences oldVarName newVarName expr)
      | _ ->
          fail "not a lamda" )


let replaceLetLHS (newLHS : string) (id : id) (ast : ast) : ast =
  wrap id ast ~f:(fun e ->
      match e with
      | ELet (id, lhsID, oldLHS, rhs, next) ->
          ELet
            ( id
            , lhsID
            , newLHS
            , rhs
            , modifyVariableOccurences oldLHS newLHS next )
      | _ ->
          fail "not a let" )


let replaceRecordField ~index (str : string) (id : id) (ast : ast) : ast =
  wrap id ast ~f:(fun e ->
      match e with
      | ERecord (id, fields) ->
          let fields =
            List.updateAt fields ~index ~f:(fun (id, _, expr) -> (id, str, expr)
            )
          in
          ERecord (id, fields)
      | _ ->
          fail "not a record" )


let deletePartial (ti : tokenInfo) (ast : ast) : ast * id =
  let id = ref (ID "no-id") in
  let ast =
    wrap (FluidToken.tid ti.token) ast ~f:(fun e ->
        match e with
        | EPartial (_, _, EBinOp (_, _, lhs, _, _)) ->
            id := eid lhs ;
            lhs
        | EPartial (_, _, _) ->
            let b = newB () in
            id := eid b ;
            b
        | _ ->
            fail "not a partial" )
  in
  (ast, !id)


let deleteBinOp (ti : tokenInfo) (ast : ast) : ast * id =
  let id = ref (ID "no-id") in
  let ast =
    wrap (FluidToken.tid ti.token) ast ~f:(fun e ->
        match e with
        | EBinOp (_, _, lhs, _, _) ->
            id := eid lhs ;
            lhs
        | _ ->
            fail "not a binop" )
  in
  (ast, !id)


let deleteRightPartial (ti : tokenInfo) (ast : ast) : ast * id =
  let id = ref (ID "no-id") in
  let ast =
    wrap (FluidToken.tid ti.token) ast ~f:(fun e ->
        match e with
        | ERightPartial (_, _, oldVal) ->
            id := eid oldVal ;
            oldVal
        | oldVal ->
            id := eid oldVal ;
            (* This uses oldval, unlike replaceWithPartial, because when a
           * partial goes to blank you're deleting it, while when a
           * rightPartial goes to blank you've only deleted the rhs *)
            oldVal )
  in
  (ast, !id)


let replaceWithPartial (str : string) (id : id) (ast : ast) : ast =
  wrap id ast ~f:(fun e ->
      let str = String.trim str in
      match e with
      | EPartial (id, _, oldVal) ->
          if str = ""
          then fail "replacing with empty partial, use delete partial instead" ;
          EPartial (id, str, oldVal)
      | oldVal ->
          if str = "" then newB () else EPartial (gid (), str, oldVal) )


let replaceWithRightPartial (str : string) (id : id) (ast : ast) : ast =
  wrap id ast ~f:(fun e ->
      let str = String.trim str in
      if str = "" then fail "replacing with empty right partial" ;
      match e with
      | ERightPartial (id, _, oldVal) ->
          ERightPartial (id, str, oldVal)
      | oldVal ->
          ERightPartial (gid (), str, oldVal) )


let removeThreadPipe (id : id) (ast : ast) (index : int) : ast =
  let index =
    (* remove expression in front of pipe, not behind it *)
    index + 1
  in
  wrap id ast ~f:(fun e ->
      match e with
      | EThread (_, [e1; _]) ->
          e1
      | EThread (id, exprs) ->
          EThread (id, List.removeAt ~index exprs)
      | _ ->
          e )


(* Supports the various different tokens replacing their string contents.
 * Doesn't do movement. *)
let replaceStringToken ~(f : string -> string) (token : token) (ast : ast) :
    fluidExpr =
  match token with
  | TString (id, str) ->
      replaceExpr id ~newExpr:(EString (id, f str)) ast
  | TPatternString (mID, id, str) ->
      replacePattern mID id ~newPat:(FPString (mID, id, f str)) ast
  | TInteger (id, str) ->
      let str = f str in
      let newExpr =
        if str = ""
        then EBlank id
        else
          let value = try safe_int_of_string str with _ -> 0 in
          EInteger (id, value)
      in
      replaceExpr id ~newExpr ast
  | TPatternInteger (mID, id, str) ->
      let str = f str in
      let newPat =
        if str = ""
        then FPBlank (mID, id)
        else
          let value = try safe_int_of_string str with _ -> 0 in
          FPInteger (mID, id, value)
      in
      replacePattern mID id ~newPat ast
  | TPatternNullToken (mID, id) ->
      let str = f "null" in
      let newExpr = FPVariable (mID, gid (), str) in
      replacePattern mID id ~newPat:newExpr ast
  | TPatternTrue (mID, id) ->
      let str = f "true" in
      let newExpr = FPVariable (mID, gid (), str) in
      replacePattern mID id ~newPat:newExpr ast
  | TPatternFalse (mID, id) ->
      let str = f "false" in
      let newExpr = FPVariable (mID, gid (), str) in
      replacePattern mID id ~newPat:newExpr ast
  | TPatternVariable (mID, _, str) ->
      replaceVarInPattern mID str (f str) ast
  | TRecordField (id, index, str) ->
      replaceRecordField ~index (f str) id ast
  | TLetLHS (id, str) ->
      replaceLetLHS (f str) id ast
  | TLambdaVar (id, index, str) ->
      replaceLamdaVar ~index str (f str) id ast
  | TVariable (id, str) ->
      replaceWithPartial (f str) id ast
  | TPartial (id, str) ->
      replaceWithPartial (f str) id ast
  | TRightPartial (id, str) ->
      replaceWithRightPartial (f str) id ast
  | TFieldName (id, _, str) ->
      replaceFieldName (f str) id ast
  | TTrue id ->
      replaceWithPartial (f "true") id ast
  | TFalse id ->
      replaceWithPartial (f "false") id ast
  | TNullToken id ->
      replaceWithPartial (f "null") id ast
  | TBinOp (id, name) ->
      replaceWithPartial (f name) id ast
  | _ ->
      fail "not supported by replaceToken"


let replaceFloatWhole (str : string) (id : id) (ast : ast) : fluidExpr =
  wrap id ast ~f:(fun expr ->
      match expr with
      | EFloat (id, _, fraction) ->
          EFloat (id, str, fraction)
      | _ ->
          fail "not a float" )


let replacePatternFloatWhole
    (str : string) (matchID : id) (patID : id) (ast : ast) : fluidExpr =
  wrapPattern matchID patID ast ~f:(fun expr ->
      match expr with
      | FPFloat (matchID, patID, _, fraction) ->
          FPFloat (matchID, patID, str, fraction)
      | _ ->
          fail "not a float" )


let replacePatternFloatFraction
    (str : string) (matchID : id) (patID : id) (ast : ast) : fluidExpr =
  wrapPattern matchID patID ast ~f:(fun expr ->
      match expr with
      | FPFloat (matchID, patID, whole, _) ->
          FPFloat (matchID, patID, whole, str)
      | _ ->
          fail "not a float" )


let removePatternPointFromFloat (matchID : id) (patID : id) (ast : ast) : ast =
  wrapPattern matchID patID ast ~f:(fun expr ->
      match expr with
      | FPFloat (matchID, _, whole, fraction) ->
          let i = safe_int_of_string (whole ^ fraction) in
          FPInteger (matchID, gid (), i)
      | _ ->
          fail "Not an int" )


let replaceFloatFraction (str : string) (id : id) (ast : ast) : fluidExpr =
  wrap id ast ~f:(fun expr ->
      match expr with
      | EFloat (id, whole, _) ->
          EFloat (id, whole, str)
      | _ ->
          fail "not a float" )


let insertAtFrontOfFloatFraction (letter : string) (id : id) (ast : ast) :
    fluidExpr =
  wrap id ast ~f:(fun expr ->
      match expr with
      | EFloat (id, whole, fraction) ->
          EFloat (id, whole, letter ^ fraction)
      | _ ->
          fail "not a float" )


let insertAtFrontOfPatternFloatFraction
    (letter : string) (matchID : id) (patID : id) (ast : ast) : fluidExpr =
  wrapPattern matchID patID ast ~f:(fun expr ->
      match expr with
      | FPFloat (matchID, patID, whole, fraction) ->
          FPFloat (matchID, patID, whole, letter ^ fraction)
      | _ ->
          fail "not a float" )


let insertInList ~(index : int) ~(newExpr : fluidExpr) (id : id) (ast : ast) :
    ast =
  wrap id ast ~f:(fun expr ->
      match expr with
      | EList (id, exprs) ->
          EList (id, List.insertAt ~index ~value:newExpr exprs)
      | _ ->
          fail "not a list" )


(* Add a blank after the expr indicated by id, which we presume is in a list *)
let addBlankToList (id : id) (ast : ast) : ast =
  let parent = findParent id ast in
  match parent with
  | Some (EList (pID, exprs)) ->
      wrap pID ast ~f:(fun expr ->
          match List.findIndex ~f:(fun e -> eid e = id) exprs with
          | Some index ->
              EList
                ( pID
                , List.insertAt
                    ~index:(index + 1)
                    ~value:(EBlank (gid ()))
                    exprs )
          | _ ->
              expr )
  | _ ->
      ast


(* Add a row to the record *)
let addRecordRowToFront (id : id) (ast : ast) : ast =
  wrap id ast ~f:(fun expr ->
      match expr with
      | ERecord (id, fields) ->
          ERecord (id, (gid (), "", newB ()) :: fields)
      | _ ->
          fail "Not a record" )


let convertToBinOp (char : char option) (id : id) (ast : ast) : ast =
  match char with
  | None ->
      ast
  | Some c ->
      wrap id ast ~f:(fun expr ->
          ERightPartial (gid (), String.fromChar c, expr) )


let convertToStringAppend (id : id) (ast : ast) : ast =
  wrap id ast ~f:(fun expr -> EBinOp (gid (), "++", expr, newB (), NoRail))


let convertIntToFloat (offset : int) (id : id) (ast : ast) : ast =
  wrap id ast ~f:(fun expr ->
      match expr with
      | EInteger (_, i) ->
          let str = Int.toString i in
          let whole, fraction = String.splitAt ~index:offset str in
          EFloat (gid (), whole, fraction)
      | _ ->
          fail "Not an int" )


let convertPatternIntToFloat
    (offset : int) (matchID : id) (patID : id) (ast : ast) : ast =
  wrapPattern matchID patID ast ~f:(fun expr ->
      match expr with
      | FPInteger (matchID, _, i) ->
          let str = Int.toString i in
          let whole, fraction = String.splitAt ~index:offset str in
          FPFloat (matchID, gid (), whole, fraction)
      | _ ->
          fail "Not an int" )


let removePointFromFloat (id : id) (ast : ast) : ast =
  wrap id ast ~f:(fun expr ->
      match expr with
      | EFloat (_, whole, fraction) ->
          let i = safe_int_of_string (whole ^ fraction) in
          EInteger (gid (), i)
      | _ ->
          fail "Not an int" )


let moveToNextNonWhitespaceToken ~pos (ast : ast) (s : state) : state =
  let s = recordAction ~pos "moveToNextNonWhitespaceToken" s in
  let rec getNextWS tokens =
    match tokens with
    | [] ->
        pos
    | ti :: rest ->
      ( match ti.token with
      | TSep | TNewline | TIndent _ | TIndentToHere _ | TIndented _ ->
          getNextWS rest
      | _ ->
          if pos > ti.startPos then getNextWS rest else ti.startPos )
  in
  let newPos = getNextWS (toTokens s ast) in
  setPosition ~resetUD:true s newPos


let moveToStartOfLine (ast : ast) (ti : tokenInfo) (s : state) : state =
  let s = recordAction "moveToStartOfLine" s in
  let token =
    toTokens s ast
    |> List.find ~f:(fun info -> info.startRow == ti.startRow)
    |> Option.withDefault ~default:ti
  in
  let newPos =
    match token.token with
    (* To prevent the cursor from going to the front of an indent*)
    | TIndent _ | TIndentToHere _ ->
        token.endPos
    | _ ->
        token.startPos
  in
  setPosition s newPos


let moveToEndOfLine (ast : ast) (ti : tokenInfo) (s : state) : state =
  let s = recordAction "moveToEndOfLine" s in
  let token =
    toTokens s ast
    |> List.reverse
    |> List.find ~f:(fun info -> info.startRow == ti.startRow)
    |> Option.withDefault ~default:ti
  in
  let newPos =
    match token.token with
    (* To prevent the cursor from going to the end of an indent or to a new line *)
    | TNewline | TIndent _ | TIndentToHere _ ->
        token.startPos
    | _ ->
        token.endPos
  in
  setPosition s newPos


let moveToEnd (ti : tokenInfo) (s : state) : state =
  let s = recordAction ~ti "moveToEnd" s in
  setPosition ~resetUD:true s (ti.endPos - 1)


let moveToStart (ti : tokenInfo) (s : state) : state =
  let s = recordAction ~ti ~pos:ti.startPos "moveToStart" s in
  setPosition ~resetUD:true s ti.startPos


let moveToAfter (ti : tokenInfo) (s : state) : state =
  let s = recordAction ~ti ~pos:ti.endPos "moveToAfter" s in
  setPosition ~resetUD:true s ti.endPos


let moveOneLeft (pos : int) (s : state) : state =
  let s = recordAction ~pos "moveOneLeft" s in
  setPosition ~resetUD:true s (max 0 (pos - 1))


let moveOneRight (pos : int) (s : state) : state =
  let s = recordAction ~pos "moveOneRight" s in
  setPosition ~resetUD:true s (pos + 1)


let moveTo (newPos : int) (s : state) : state =
  let s = recordAction ~pos:newPos "moveTo" s in
  setPosition s newPos


(* Starting from somewhere after the location, move back until we reach the
 * `target` expression, and return a state with it's location. If blank, will
 * go to the start of the blank *)
let moveBackTo (target : id) (ast : ast) (s : state) : state =
  let s = recordAction "moveBackTo" s in
  let tokens = toTokens s ast in
  match
    List.find (List.reverse tokens) ~f:(fun ti ->
        FluidToken.tid ti.token = target )
  with
  | None ->
      fail "cannot find token to moveBackTo"
  | Some lastToken ->
      let newPos =
        if FluidToken.isBlank lastToken.token
        then lastToken.startPos
        else lastToken.endPos
      in
      moveTo newPos s


let rec getNextBlank (pos : int) (tokens : tokenInfo list) : tokenInfo option =
  tokens
  |> List.find ~f:(fun ti -> Token.isBlank ti.token && ti.startPos > pos)
  |> Option.orElseLazy (fun () ->
         if pos = 0 then None else getNextBlank 0 tokens )


let getNextBlankPos (pos : int) (tokens : tokenInfo list) : int =
  tokens
  |> getNextBlank pos
  |> Option.map ~f:(fun ti -> ti.startPos)
  |> Option.withDefault ~default:pos


let moveToNextBlank ~(pos : int) (ast : ast) (s : state) : state =
  let s = recordAction ~pos "moveToNextBlank" s in
  let tokens = toTokens s ast in
  let newPos = getNextBlankPos pos tokens in
  setPosition ~resetUD:true s newPos


let rec getPrevBlank (pos : int) (tokens : tokenInfo list) : tokenInfo option =
  tokens
  |> List.filter ~f:(fun ti -> Token.isBlank ti.token && ti.endPos < pos)
  |> List.last
  |> Option.orElseLazy (fun () ->
         let lastPos =
           List.last tokens
           |> Option.map ~f:(fun ti -> ti.endPos)
           |> Option.withDefault ~default:0
         in
         if pos = lastPos then None else getPrevBlank lastPos tokens )


let getPrevBlankPos (pos : int) (tokens : tokenInfo list) : int =
  tokens
  |> getPrevBlank pos
  |> Option.map ~f:(fun ti -> ti.startPos)
  |> Option.withDefault ~default:pos


let moveToPrevBlank ~(pos : int) (ast : ast) (s : state) : state =
  let s = recordAction ~pos "moveToPrevBlank" s in
  let tokens = toTokens s ast in
  let newPos = getPrevBlankPos pos tokens in
  setPosition ~resetUD:true s newPos


(* -------------------- *)
(* Autocomplete *)
(* -------------------- *)

let acToExpr (entry : Types.fluidAutocompleteItem) : fluidExpr * int =
  match entry with
  | FACFunction fn ->
      let count = List.length fn.fnParameters in
      let name = fn.fnName in
      let r =
        if List.member ~value:fn.fnReturnTipe Runtime.errorRailTypes
        then Types.Rail
        else Types.NoRail
      in
      let args = List.initialize count (fun _ -> EBlank (gid ())) in
      if fn.fnInfix
      then
        match args with
        | [lhs; rhs] ->
            (EBinOp (gid (), name, lhs, rhs, r), 0)
        | _ ->
            fail "BinOp doesn't have 2 args"
      else (EFnCall (gid (), name, args, r), String.length name + 1)
  | FACKeyword KLet ->
      (ELet (gid (), gid (), "", newB (), newB ()), 4)
  | FACKeyword KIf ->
      (EIf (gid (), newB (), newB (), newB ()), 3)
  | FACKeyword KLambda ->
      (ELambda (gid (), [(gid (), "")], newB ()), 1)
  | FACKeyword KMatch ->
      let matchID = gid () in
      (EMatch (matchID, newB (), [(FPBlank (matchID, gid ()), newB ())]), 6)
  | FACKeyword KThread ->
      (EThread (gid (), [newB (); newB ()]), 8)
  | FACVariable name ->
      (EVariable (gid (), name), String.length name)
  | FACLiteral "true" ->
      (EBool (gid (), true), 4)
  | FACLiteral "false" ->
      (EBool (gid (), false), 5)
  | FACLiteral "null" ->
      (ENull (gid ()), 4)
  | FACConstructorName (name, argCount) ->
      let argCount = List.initialize argCount (fun _ -> EBlank (gid ())) in
      (EConstructor (gid (), gid (), name, argCount), 1 + String.length name)
  | FACPattern _ ->
      fail
        ( "TODO: patterns are not supported here: "
        ^ Types.show_fluidAutocompleteItem entry )
  | FACField _ ->
      fail
        ( "TODO: fieldnames are not supported yet: "
        ^ Types.show_fluidAutocompleteItem entry )
  | FACLiteral _ ->
      fail
        ( "invalid literal in autocomplete: "
        ^ Types.show_fluidAutocompleteItem entry )


let acUpdateExpr (id : id) (ast : ast) (entry : Types.fluidAutocompleteItem) :
    fluidExpr * int =
  let newExpr, offset = acToExpr entry in
  let oldExpr = findExpr id ast in
  match (oldExpr, newExpr) with
  (* A partial - fetch the old nested exprs and put them in place *)
  | ( Some (EPartial (_, _, EBinOp (_, _, lhs, rhs, _)))
    , EBinOp (id, name, _, _, str) ) ->
      (EBinOp (id, name, lhs, rhs, str), String.length name)
      (* A right partial - insert the oldExpr into the first slot *)
  | Some (ERightPartial (_, _, oldExpr)), EThread (id, _head :: tail) ->
      (EThread (id, oldExpr :: tail), 2)
  | Some (ERightPartial (_, _, oldExpr)), EBinOp (id, name, _, rhs, str) ->
      (EBinOp (id, name, oldExpr, rhs, str), String.length name)
  | _ ->
      (newExpr, offset)


let acToPattern (entry : Types.fluidAutocompleteItem) : fluidPattern * int =
  match entry with
  | FACPattern p ->
    ( match p with
    | FPAConstructor (mID, patID, var, pats) ->
        (FPConstructor (mID, patID, var, pats), String.length var + 1)
    | FPAVariable (mID, patID, var) ->
        (FPVariable (mID, patID, var), String.length var + 1)
    | FPABool (mID, patID, var) ->
        (FPBool (mID, patID, var), String.length (string_of_bool var) + 1)
    | FPANull (mID, patID) ->
        (FPNull (mID, patID), 4) )
  | _ ->
      fail
        "got fluidAutocompleteItem of non `FACPattern` variant - this should never occur"


let initAC (s : state) (m : Types.model) : state = {s with ac = AC.init m}

let isAutocompleting (ti : tokenInfo) (s : state) : bool =
  Token.isAutocompletable ti.token
  && s.upDownCol = None
  && s.ac.index <> None
  && s.newPos <= ti.endPos
  && s.newPos >= ti.startPos


let acSetIndex (i : int) (s : state) : state =
  let s = recordAction "acSetIndex" s in
  {s with ac = {s.ac with index = Some i}; upDownCol = None}


let acClear (s : state) : state =
  let s = recordAction "acClear" s in
  {s with ac = {s.ac with index = None}}


let acShow (s : state) : state =
  let s = recordAction "acShow" s in
  if s.ac.index = None then {s with ac = {s.ac with index = Some 0}} else s


let acMoveUp (s : state) : state =
  let s = recordAction "acMoveUp" s in
  let index =
    match s.ac.index with None -> 0 | Some current -> max 0 (current - 1)
  in
  acSetIndex index s


let acMoveDown (s : state) : state =
  let s = recordAction "acMoveDown" s in
  let index =
    match s.ac.index with
    | None ->
        0
    | Some current ->
        min (current + 1) (List.length (AC.allCompletions s.ac) - 1)
  in
  acSetIndex index s


let moveBasedOnKey
    (key : K.key) (startPos : int) (offset : int) (s : state) (ast : ast) :
    state =
  let tokens = toTokens s ast in
  let nextBlank = getNextBlankPos s.newPos tokens in
  let prevBlank = getPrevBlankPos s.newPos tokens in
  let newPos =
    match key with
    | K.Tab ->
        nextBlank
    | K.ShiftTab ->
        prevBlank
    | K.Enter ->
        startPos + offset
    | K.Space ->
        (* if new position is after next blank, stay in next blank *)
        min nextBlank (startPos + offset + 1)
    | _ ->
        s.newPos
  in
  let newState = moveTo newPos (acClear s) in
  newState


let acEnter (ti : tokenInfo) (ast : ast) (s : state) (key : K.key) :
    ast * state =
  let s = recordAction ~ti "acEnter" s in
  match AC.highlighted s.ac with
  | None ->
    ( match ti.token with
    | TPatternVariable _ ->
        (ast, moveToNextBlank ~pos:s.newPos ast s)
    | _ ->
        (ast, s) )
  | Some entry ->
      let id = Token.tid ti.token in
      let newAST, offset =
        match ti.token with
        (* since patterns have no partial but commit as variables
        * automatically, allow intermediate variables to
        * be autocompletable to other expressions *)
        | TPatternBlank (mID, pID) | TPatternVariable (mID, pID, _) ->
            let newPat, acOffset = acToPattern entry in
            let newAST = replacePattern ~newPat mID pID ast in
            (newAST, acOffset)
        | TPartial _ | TRightPartial _ ->
            let newExpr, offset = acUpdateExpr id ast entry in
            let newAST = replaceExpr ~newExpr id ast in
            (newAST, offset)
        | _ ->
            let newExpr, offset = acToExpr entry in
            let newAST = replaceExpr ~newExpr id ast in
            (newAST, offset)
      in
      (newAST, moveBasedOnKey key ti.startPos offset s newAST)


let commitIfValid (newPos : int) (ti : tokenInfo) ((ast, s) : ast * fluidState)
    : ast =
  let highlightedText = s.ac |> AC.highlighted |> Option.map ~f:AC.asName in
  let isInside = newPos >= ti.startPos && newPos <= ti.endPos in
  if (not isInside) && Some (Token.toText ti.token) = highlightedText
  then
    let newAST, _ = acEnter ti ast s K.Enter in
    newAST
  else ast


let acMaybeCommit (newPos : int) (ast : ast) (s : fluidState) : ast =
  match s.ac.query with
  | Some (_, ti) ->
      commitIfValid newPos ti (ast, s)
  | None ->
      ast


let acCompleteField (ti : tokenInfo) (ast : ast) (s : state) : ast * state =
  let s = recordAction ~ti "acCompleteField" s in
  match AC.highlighted s.ac with
  | None ->
      (ast, s)
  | Some entry ->
      let newExpr, length = acToExpr entry in
      let newExpr = EFieldAccess (gid (), newExpr, gid (), "") in
      let length = length + 1 in
      let newState = moveTo (ti.startPos + length) (acClear s) in
      let newAST = replaceExpr ~newExpr (Token.tid ti.token) ast in
      (newAST, newState)


(* -------------------- *)
(* Code entering/interaction *)
(* -------------------- *)

let doLeft ~(pos : int) (ti : tokenInfo) (s : state) : state =
  let s = recordAction ~ti ~pos "doLeft" s in
  if Token.isAtom ti.token
  then moveToStart ti s
  else moveOneLeft (min pos ti.endPos) s


let doRight
    ~(pos : int) ~(next : tokenInfo option) (current : tokenInfo) (s : state) :
    state =
  let s = recordAction ~ti:current ~pos "doRight" s in
  if Token.isAtom current.token
  then
    match next with
    | None ->
        moveToAfter current s
    | Some nInfo ->
        moveToStart nInfo s
  else
    match next with
    | Some n when pos + 1 >= current.endPos ->
        moveToStart n s
    | _ ->
        (* When we're in whitespace, current is the next non-whitespace. So we
         * don't want to use pos, we want to use the startPos of current. *)
        let startingPos = max pos (current.startPos - 1) in
        moveOneRight startingPos s


let doUp ~(pos : int) (ast : ast) (s : state) : state =
  let s = recordAction ~pos "doUp" s in
  let tokens = toTokens s ast in
  let {row; col} = gridFor ~pos tokens in
  let col = match s.upDownCol with None -> col | Some savedCol -> savedCol in
  if row = 0
  then moveTo 0 s
  else
    let pos = adjustedPosFor ~row:(row - 1) ~col tokens in
    moveTo pos {s with upDownCol = Some col}


let doDown ~(pos : int) (ast : ast) (s : state) : state =
  let s = recordAction ~pos "doDown" s in
  let tokens = toTokens s ast in
  let {row; col} = gridFor ~pos tokens in
  let col = match s.upDownCol with None -> col | Some savedCol -> savedCol in
  let pos = adjustedPosFor ~row:(row + 1) ~col tokens in
  moveTo pos {s with upDownCol = Some col}


let doBackspace ~(pos : int) (ti : tokenInfo) (ast : ast) (s : state) :
    ast * state =
  let s = recordAction ~pos ~ti "doBackspace" s in
  let left s = moveOneLeft (min pos ti.endPos) s in
  let offset =
    match ti.token with
    | TPatternString _ | TString _ ->
        pos - ti.startPos - 2
    | _ ->
        pos - ti.startPos - 1
  in
  let newID = gid () in
  match ti.token with
  | TIfThenKeyword _ | TIfElseKeyword _ | TLambdaArrow _ | TMatchSep _ ->
      (ast, moveToStart ti s)
  | TIfKeyword _ | TLetKeyword _ | TLambdaSymbol _ | TMatchKeyword _ ->
      let newAST = removeEmptyExpr (Token.tid ti.token) ast in
      if newAST = ast then (ast, s) else (newAST, moveToStart ti s)
  | TString (id, "") ->
      (replaceExpr id ~newExpr:(EBlank newID) ast, left s)
  | TPatternString (mID, id, "") ->
      (replacePattern mID id ~newPat:(FPBlank (mID, newID)) ast, left s)
  | (TRecordOpen id | TListOpen id) when exprIsEmpty id ast ->
      (replaceExpr id ~newExpr:(EBlank newID) ast, left s)
  | TRecordField (id, i, "") when pos = ti.startPos ->
      ( removeRecordField id i ast
      , s |> left |> fun s -> moveOneLeft (s.newPos - 1) s )
  | TBlank _
  | TPlaceholder _
  | TIndent _
  | TIndentToHere _
  | TIndented _
  | TLetAssignment _
  | TListClose _
  | TListOpen _
  | TListSep _
  | TNewline
  | TRecordOpen _
  | TRecordClose _
  | TRecordSep _
  | TSep
  | TLambdaSep _
  | TPatternBlank _
  | TPatternConstructorName _
  | TPartialGhost _ ->
      (ast, left s)
  | TFieldOp id ->
      (removeField id ast, left s)
  | TFloatPoint id ->
      (removePointFromFloat id ast, left s)
  | TPatternFloatPoint (mID, id) ->
      (removePatternPointFromFloat mID id ast, left s)
  | TConstructorName (id, _) | TFnName (id, _, _) ->
      (deleteWithArguments id ast, moveToStart ti s)
  | TRightPartial (_, str) when String.length str = 1 ->
      let ast, targetID = deleteRightPartial ti ast in
      (ast, moveBackTo targetID ast s)
  | TPartial (_, str) when String.length str = 1 ->
      let ast, targetID = deletePartial ti ast in
      (ast, moveBackTo targetID ast s)
  | TBinOp (_, str) when String.length str = 1 ->
      let ast, targetID = deleteBinOp ti ast in
      (ast, moveBackTo targetID ast s)
  | TString _
  | TPatternString _
  | TRecordField _
  | TInteger _
  | TTrue _
  | TFalse _
  | TPatternTrue _
  | TPatternFalse _
  | TNullToken _
  | TVariable _
  | TFieldName _
  | TLetLHS _
  | TPatternInteger _
  | TPatternNullToken _
  | TPatternVariable _
  | TRightPartial _
  | TPartial _
  | TBinOp _
  | TLambdaVar _ ->
      let f str = removeCharAt str offset in
      (replaceStringToken ~f ti.token ast, left s)
  | TPatternFloatWhole (mID, id, str) ->
      let str = removeCharAt str offset in
      (replacePatternFloatWhole str mID id ast, left s)
  | TPatternFloatFraction (mID, id, str) ->
      let str = removeCharAt str offset in
      (replacePatternFloatFraction str mID id ast, left s)
  | TFloatWhole (id, str) ->
      let str = removeCharAt str offset in
      (replaceFloatWhole str id ast, left s)
  | TFloatFraction (id, str) ->
      let str = removeCharAt str offset in
      (replaceFloatFraction str id ast, left s)
  | TThreadPipe (id, i) ->
      let s =
        match getTokensAtPosition ~pos:ti.startPos (toTokens s ast) with
        | Some leftTI, _, _ ->
            doLeft ~pos:ti.startPos leftTI s
        | _ ->
            fail "TThreadPipe should never occur on first line of AST"
      in
      (removeThreadPipe id ast i, s)


let doDelete ~(pos : int) (ti : tokenInfo) (ast : ast) (s : state) :
    ast * state =
  let s = recordAction ~pos ~ti "doDelete" s in
  let left s = moveOneLeft pos s in
  let offset = pos - ti.startPos in
  let newID = gid () in
  let f str = removeCharAt str offset in
  match ti.token with
  | TIfThenKeyword _ | TIfElseKeyword _ | TLambdaArrow _ | TMatchSep _ ->
      (ast, s)
  | TIfKeyword _ | TLetKeyword _ | TLambdaSymbol _ | TMatchKeyword _ ->
      (removeEmptyExpr (Token.tid ti.token) ast, s)
  | (TListOpen id | TRecordOpen id) when exprIsEmpty id ast ->
      (replaceExpr id ~newExpr:(newB ()) ast, s)
  | TBlank _
  | TPlaceholder _
  | TIndent _
  | TIndentToHere _
  | TIndented _
  | TLetAssignment _
  | TListClose _
  | TListOpen _
  | TListSep _
  | TNewline
  | TRecordClose _
  | TRecordOpen _
  | TRecordSep _
  | TSep
  | TLambdaSep _
  | TPartialGhost _ ->
      (ast, s)
  | TBinOp (id, _) ->
      (* TODO this should move to the start of the new blank, but we don't know
       * where it is at the moment. *)
      (deleteWithArguments id ast, moveToStart ti s |> left)
  | TConstructorName (id, _) | TFnName (id, _, _) ->
      (deleteWithArguments id ast, moveToStart ti s)
  | TFieldOp id ->
      (removeField id ast, s)
  | TString (id, str) ->
      let target s =
        (* if we're in front of the quotes vs within it *)
        if offset == 0 then s else left s
      in
      if str = ""
      then (ast |> replaceExpr id ~newExpr:(EBlank newID), target s)
      else
        let str = removeCharAt str (offset - 1) in
        (replaceExpr id ~newExpr:(EString (newID, str)) ast, s)
  | TPatternString (mID, id, str) ->
      let target s =
        (* if we're in front of the quotes vs within it *)
        if offset == 0 then s else left s
      in
      if str = ""
      then
        (ast |> replacePattern mID id ~newPat:(FPBlank (mID, newID)), target s)
      else
        let str = removeCharAt str (offset - 1) in
        (replacePattern mID id ~newPat:(FPString (mID, newID, str)) ast, s)
  | TRecordField _
  | TInteger _
  | TPatternInteger _
  | TTrue _
  | TFalse _
  | TNullToken _
  | TVariable _
  | TPartial _
  | TRightPartial _
  | TFieldName _
  | TLetLHS _
  | TPatternNullToken _
  | TPatternTrue _
  | TPatternFalse _
  | TPatternVariable _
  | TLambdaVar _ ->
      (replaceStringToken ~f ti.token ast, s)
  | TFloatPoint id ->
      (removePointFromFloat id ast, s)
  | TFloatWhole (id, str) ->
      (replaceFloatWhole (f str) id ast, s)
  | TFloatFraction (id, str) ->
      (replaceFloatFraction (f str) id ast, s)
  | TPatternFloatPoint (mID, id) ->
      (removePatternPointFromFloat mID id ast, s)
  | TPatternFloatFraction (mID, id, str) ->
      (replacePatternFloatFraction (f str) mID id ast, s)
  | TPatternFloatWhole (mID, id, str) ->
      (replacePatternFloatWhole (f str) mID id ast, s)
  | TPatternConstructorName (mID, id, _) ->
      (replacePattern ~newPat:(FPBlank (mID, id)) mID id ast, s)
  | TPatternBlank _ ->
      (ast, s)
  | TThreadPipe (id, i) ->
      (removeThreadPipe id ast i, s)


let doInsert' ~pos (letter : char) (ti : tokenInfo) (ast : ast) (s : state) :
    ast * state =
  let s = recordAction ~ti ~pos "doInsert" s in
  let s = {s with upDownCol = None} in
  let letterStr = String.fromChar letter in
  let offset =
    match ti.token with
    | TString _ | TPatternString _ ->
        pos - ti.startPos - 1
    | _ ->
        pos - ti.startPos
  in
  let right = moveOneRight pos s in
  let f str = String.insertAt ~index:offset ~insert:letterStr str in
  let newID = gid () in
  let newExpr =
    if letter = '"'
    then EString (newID, "")
    else if letter = '['
    then EList (newID, [])
    else if letter = '{'
    then ERecord (newID, [])
    else if letter = '\\'
    then ELambda (newID, [(gid (), "")], EBlank (gid ()))
    else if letter = ','
    then EBlank newID (* new separators *)
    else if isNumber letterStr
    then EInteger (newID, letterStr |> safe_int_of_string)
    else EPartial (newID, letterStr, EBlank (gid ()))
  in
  match ti.token with
  | (TFieldName (id, _, _) | TVariable (id, _))
    when pos = ti.endPos && letter = '.' ->
      (exprToFieldAccess id ast, right)
  (* replace blank *)
  | TBlank id | TPlaceholder (_, id) ->
      (replaceExpr id ~newExpr ast, moveTo (ti.startPos + 1) s)
  (* lists *)
  | TListOpen id ->
      (insertInList ~index:0 id ~newExpr ast, moveTo (ti.startPos + 2) s)
  (* Ignore invalid situations *)
  | TString _ when offset < 0 ->
      (ast, s)
  | TPatternString _ when offset < 0 ->
      (ast, s)
  | TInteger _ when not (isNumber letterStr) ->
      (ast, s)
  | TInteger _ when '0' = letter && offset = 0 ->
      (ast, s)
  | TPatternInteger _ when not (isNumber letterStr) ->
      (ast, s)
  | TPatternInteger _ when '0' = letter && offset = 0 ->
      (ast, s)
  | TFloatWhole _ when not (isNumber letterStr) ->
      (ast, s)
  | TFloatWhole _ when '0' = letter && offset = 0 ->
      (ast, s)
  | TFloatFraction _ when not (isNumber letterStr) ->
      (ast, s)
  | TPatternFloatWhole _ when not (isNumber letterStr) ->
      (ast, s)
  | TPatternFloatWhole _ when '0' = letter && offset = 0 ->
      (ast, s)
  | TPatternFloatFraction _ when not (isNumber letterStr) ->
      (ast, s)
  | TVariable _ when not (isIdentifierChar letterStr) ->
      (ast, s)
  | TPatternVariable _ when not (isIdentifierChar letterStr) ->
      (ast, s)
  | TLetLHS _ when not (isIdentifierChar letterStr) ->
      (ast, s)
  | TFieldName _ when not (isIdentifierChar letterStr) ->
      (ast, s)
  | TLambdaVar _ when not (isIdentifierChar letterStr) ->
      (ast, s)
  | TFnName _ when not (isFnNameChar letterStr) ->
      (ast, s)
  (* Do the insert *)
  | TLetLHS (_, "") ->
      (replaceStringToken ~f ti.token ast, moveTo (ti.startPos + 1) s)
  | TRecordField _
  | TFieldName _
  | TVariable _
  | TPartial _
  | TRightPartial _
  | TString _
  | TPatternString _
  | TLetLHS _
  | TTrue _
  | TFalse _
  | TPatternTrue _
  | TPatternFalse _
  | TNullToken _
  | TPatternNullToken _
  | TPatternVariable _
  | TBinOp _
  | TLambdaVar _ ->
      (replaceStringToken ~f ti.token ast, right)
  | TPatternInteger (_, _, i) | TInteger (_, i) ->
      let newLength =
        f i |> safe_int_of_string |> string_of_int |> String.length
      in
      let move = if newLength > offset then right else s in
      (replaceStringToken ~f ti.token ast, move)
  | TFloatWhole (id, str) ->
      (replaceFloatWhole (f str) id ast, right)
  | TFloatFraction (id, str) ->
      (replaceFloatFraction (f str) id ast, right)
  | TFloatPoint id ->
      (insertAtFrontOfFloatFraction letterStr id ast, right)
  | TPatternFloatWhole (mID, id, str) ->
      (replacePatternFloatWhole (f str) mID id ast, right)
  | TPatternFloatFraction (mID, id, str) ->
      (replacePatternFloatFraction (f str) mID id ast, right)
  | TPatternFloatPoint (mID, id) ->
      (insertAtFrontOfPatternFloatFraction letterStr mID id ast, right)
  | TPatternConstructorName _ ->
      (ast, s)
  | TPatternBlank (mID, pID) ->
      let newPat =
        if letter = '"'
        then FPString (mID, newID, "")
        else if isNumber letterStr
        then FPInteger (mID, newID, letterStr |> safe_int_of_string)
        else FPVariable (mID, newID, letterStr)
      in
      (replacePattern mID pID ~newPat ast, moveTo (ti.startPos + 1) s)
  (* do nothing *)
  | TNewline
  | TIfKeyword _
  | TIfThenKeyword _
  | TIfElseKeyword _
  | TFieldOp _
  | TFnName _
  | TLetKeyword _
  | TLetAssignment _
  | TSep
  | TIndented _
  | TIndentToHere _
  | TListClose _
  | TListSep _
  | TIndent _
  | TRecordOpen _
  | TRecordClose _
  | TRecordSep _
  | TThreadPipe _
  | TLambdaSymbol _
  | TLambdaArrow _
  | TConstructorName _
  | TLambdaSep _
  | TMatchSep _
  | TMatchKeyword _
  | TPartialGhost _ ->
      (ast, s)


let doInsert
    ~pos (letter : char option) (ti : tokenInfo) (ast : ast) (s : state) :
    ast * state =
  match letter with
  | None ->
      (ast, s)
  | Some letter ->
      doInsert' ~pos letter ti ast s


let maybeOpenCmd (m : Types.model) : Types.modification =
  let getCurrentToken tokens =
    let _, mCurrent, _ = getTokensAtPosition tokens ~pos:m.fluidState.newPos in
    mCurrent
  in
  Toplevel.selected m
  |> Option.andThen ~f:(fun tl ->
         TL.rootExpr tl
         |> Option.andThen ~f:(fun ast -> Some (fromExpr m.fluidState ast))
         |> Option.andThen ~f:(fun ast -> Some (toTokens m.fluidState ast))
         |> Option.withDefault ~default:[]
         |> getCurrentToken
         |> Option.andThen ~f:(fun ti ->
                let id = Token.tid ti.token in
                Some (FluidCommandsFor (tl.id, id)) ) )
  |> Option.withDefault ~default:NoChange


let updateKey (key : K.key) (ast : ast) (s : state) : ast * state =
  let pos = s.newPos in
  let keyChar = K.toChar key in
  let tokens = toTokens s ast in
  (* These might be the same token *)
  let toTheLeft, toTheRight, mNext = getNeighbours ~pos tokens in
  let onEdge =
    match (toTheLeft, toTheRight) with
    | L (lt, lti), R (rt, rti) ->
        (lt, lti) <> (rt, rti)
    | _ ->
        true
  in
  let infixKeys =
    [ K.Plus
    ; K.Percent
    ; K.Minus
    ; K.Multiply
    ; K.ForwardSlash
    ; K.LessThan
    ; K.GreaterThan
    ; K.Ampersand
    ; K.Pipe ]
  in
  let newAST, newState =
    (* TODO: When changing TVariable and TFieldName and probably TFnName we
     * should convert them to a partial which retains the old object *)
    match (key, toTheLeft, toTheRight) with
    (* Deleting *)
    | K.Backspace, L (TPatternString _, ti), _
    | K.Backspace, L (TString _, ti), _
      when pos = ti.endPos ->
        (* Backspace should move into a string, not delete it *)
        (ast, moveOneLeft pos s)
    | K.Backspace, _, R (TRecordField (_, _, ""), ti) ->
        doBackspace ~pos ti ast s
    | K.Backspace, L (_, ti), _ ->
        doBackspace ~pos ti ast s
    | K.Delete, _, R (_, ti) ->
        doDelete ~pos ti ast s
    (* Autocomplete menu *)
    (* Note that these are spelt out explicitly on purpose, else they'll
     * trigger on the wrong element sometimes. *)
    | K.Escape, L (_, ti), _ when isAutocompleting ti s ->
        (ast, acClear s)
    | K.Escape, _, R (_, ti) when isAutocompleting ti s ->
        (ast, acClear s)
    | K.Up, _, R (_, ti) when isAutocompleting ti s ->
        (ast, acMoveUp s)
    | K.Up, L (_, ti), _ when isAutocompleting ti s ->
        (ast, acMoveUp s)
    | K.Down, _, R (_, ti) when isAutocompleting ti s ->
        (ast, acMoveDown s)
    | K.Down, L (_, ti), _ when isAutocompleting ti s ->
        (ast, acMoveDown s)
    (* Autocomplete finish *)
    | _, L (_, ti), _
      when isAutocompleting ti s
           && [K.Enter; K.Tab; K.ShiftTab; K.Space] |> List.member ~value:key
      ->
        acEnter ti ast s key
    | _, _, R (_, ti)
      when isAutocompleting ti s
           && [K.Enter; K.Tab; K.ShiftTab; K.Space] |> List.member ~value:key
      ->
        acEnter ti ast s key
    (* When we type a letter/number after an infix operator, complete and
     * then enter the number/letter. *)
    | K.Number _, L (TRightPartial (_, _), ti), _
    | K.Letter _, L (TRightPartial (_, _), ti), _
      when onEdge ->
        let ast, s = acEnter ti ast s K.Tab in
        let ti =
          getLeftTokenAt s.newPos (toTokens s ast |> List.reverse)
          |> deOption "rightPartialLetter/number"
        in
        doInsert ~pos:s.newPos keyChar ti ast s
    (* Special autocomplete entries *)
    (* press dot while in a variable entry *)
    | K.Period, L (TPartial _, ti), _
      when Option.map ~f:AC.isVariable (AC.highlighted s.ac) = Some true ->
        acCompleteField ti ast s
    (* Tab to next blank *)
    | K.Tab, _, R (_, _) | K.Tab, L (_, _), _ ->
        (ast, moveToNextBlank ~pos ast s)
    | K.ShiftTab, _, R (_, _) | K.ShiftTab, L (_, _), _ ->
        (ast, moveToPrevBlank ~pos ast s)
    (* TODO: press comma while in an expr in a list *)
    (* TODO: press comma while in an expr in a record *)
    (* TODO: press equals when in a let *)
    (* TODO: press colon when in a record field *)
    (* Left/Right movement *)
    | K.Left, L (_, ti), _ ->
        (ast, doLeft ~pos ti s |> acShow)
    | K.Right, _, R (_, ti) ->
        (ast, doRight ~pos ~next:mNext ti s |> acShow)
    | K.GoToStartOfLine, _, R (_, ti) | K.GoToStartOfLine, L (_, ti), _ ->
        (ast, moveToStartOfLine ast ti s)
    | K.GoToEndOfLine, _, R (_, ti) ->
        (ast, moveToEndOfLine ast ti s |> acShow)
    | K.Up, _, _ ->
        (ast, doUp ~pos ast s)
    | K.Down, _, _ ->
        (ast, doDown ~pos ast s)
    | K.Space, _, R (TSep, _) ->
        (ast, moveOneRight pos s)
    (* list-specific insertions *)
    | K.Comma, L (TListOpen _, toTheLeft), _ ->
        doInsert ~pos keyChar toTheLeft ast s
    | K.Comma, L (t, ti), _ ->
        if onEdge
        then (addBlankToList (Token.tid t) ast, moveOneRight ti.endPos s)
        else doInsert ~pos keyChar ti ast s
    | K.RightCurlyBrace, _, R (TRecordClose _, ti) when pos = ti.endPos - 1 ->
        (* Allow pressing close curly to go over the last curly *)
        (ast, moveOneRight pos s)
    (* Record-specific insertions *)
    | K.Enter, L (TRecordOpen id, _), _ ->
        let newAST = addRecordRowToFront id ast in
        (newAST, moveToNextNonWhitespaceToken ~pos newAST s)
    | K.RightSquareBracket, _, R (TListClose _, ti) when pos = ti.endPos - 1 ->
        (* Allow pressing close square to go over the last square *)
        (ast, moveOneRight pos s)
    (* Lambda-specific insertions *)
    (* String-specific insertions *)
    | K.DoubleQuote, _, R (TPatternString _, ti)
    | K.DoubleQuote, _, R (TString _, ti)
      when pos = ti.endPos - 1 ->
        (* Allow pressing quote to go over the last quote *)
        (ast, moveOneRight pos s)
    (* Field access *)
    | K.Period, L (TVariable _, toTheLeft), _
    | K.Period, L (TFieldName _, toTheLeft), _
      when onEdge ->
        doInsert ~pos keyChar toTheLeft ast s
    (* Int to float *)
    | K.Period, L (TInteger (id, _), ti), _ ->
        let offset = pos - ti.startPos in
        (convertIntToFloat offset id ast, moveOneRight pos s)
    | K.Period, L (TPatternInteger (mID, id, _), ti), _ ->
        let offset = pos - ti.startPos in
        (convertPatternIntToFloat offset mID id ast, moveOneRight pos s)
    (* Binop specific *)
    | key, L (TPartial _, toTheLeft), _
    | key, L (TRightPartial _, toTheLeft), _
    | key, L (TBinOp _, toTheLeft), _
      when List.member ~value:key infixKeys ->
        doInsert ~pos keyChar toTheLeft ast s
    | key, L (_, toTheLeft), _ when onEdge && List.member ~value:key infixKeys
      ->
        ( convertToBinOp keyChar (Token.tid toTheLeft.token) ast
        , s |> moveTo (pos + 2) )
    (* End of line *)
    | K.Enter, _, R (TNewline, ti) ->
        (ast, doRight ~pos ~next:mNext ti s)
    (* Let specific *)
    | K.Equals, _, R (TLetAssignment _, toTheRight) ->
        (ast, moveTo toTheRight.endPos s)
    (* Rest of Insertions *)
    | _, L (TListOpen _, toTheLeft), R (TListClose _, _) ->
        doInsert ~pos keyChar toTheLeft ast s
    | _, L (_, toTheLeft), _ when Token.isAppendable toTheLeft.token ->
        doInsert ~pos keyChar toTheLeft ast s
    | _, _, R (TListOpen _, _) ->
        (ast, s)
    | _, _, R (_, toTheRight) ->
        doInsert ~pos keyChar toTheRight ast s
    | _ ->
        (* Unknown *)
        (ast, report ("Unknown action: " ^ K.toName key) s)
  in
  (* If we were on a partial and have moved off it, we may want to commit
   * that partial. This is done here because the logic is different that
   * clicking. *)
  match (key, toTheLeft, toTheRight) with
  | K.Number _, _, _ | K.Letter _, _, _ ->
      (newAST, newState)
  | _, L (TPartial _, ti), _ | _, _, R (TPartial _, ti) ->
      (* Use the old position and ac and token *)
      let committedAST = commitIfValid newState.newPos ti (newAST, s) in
      (* TODO: I tried redoing the action after it had been committed, but in
       * the cases I tried it didn't have a better user experience. Might be
       * edge cases I didn't consider though. *)
      (committedAST, newState)
  | _ ->
      (newAST, newState)


let updateAutocomplete m tlid ast s : fluidState =
  let tokens = toTokens s ast in
  let ti =
    let toTheLeft, toTheRight, _ = getNeighbours ~pos:s.newPos tokens in
    match (toTheLeft, toTheRight) with
    | _, R (_, ti)
      when Token.isTextToken ti.token && Token.isAutocompletable ti.token ->
        Some ti
    | L (_, ti), _
      when Token.isTextToken ti.token && Token.isAutocompletable ti.token ->
        Some ti
    | _ ->
        None
  in
  match ti with
  | Some ti ->
      let m = TL.withAST m tlid (toExpr ast) in
      let newAC = AC.regenerate m s.ac (tlid, ti) in
      {s with ac = newAC}
  | None ->
      s


let updateMouseClick (newPos : int) (ast : ast) (s : fluidState) :
    ast * fluidState =
  let tokens = toTokens s ast in
  let lastPos =
    tokens
    |> List.last
    |> Option.map ~f:(fun ti -> ti.endPos)
    |> Option.withDefault ~default:0
  in
  let newPos = if newPos > lastPos then lastPos else newPos in
  let newPos =
    (* TODO: add tests for clicking in the middle of a thread pipe (or blank) *)
    match getLeftTokenAt newPos tokens with
    | Some current when Token.isBlank current.token ->
        current.startPos
    | Some ({token = TThreadPipe _} as current) ->
        current.endPos
    | _ ->
        newPos
  in
  let newAST = acMaybeCommit newPos ast s in
  (newAST, setPosition s newPos)


let shouldDoDefaultAction (key : K.key) : bool =
  match key with
  | K.GoToStartOfLine | K.GoToEndOfLine | K.Delete ->
      false
  | _ ->
      true


let updateMsg m tlid (ast : ast) (msg : Types.msg) (s : fluidState) :
    ast * fluidState =
  (* TODO: The state should be updated from the last request, and so this
   * shouldn't be necessary, but the tests don't work without it *)
  let s = updateAutocomplete m tlid ast s in
  let newAST, newState =
    match msg with
    | FluidMouseClick ->
      (* TODO: if mouseclick on blank put cursor at beginning of it *)
      ( match Entry.getCursorPosition () with
      | Some newPos ->
          updateMouseClick newPos ast s
      | None ->
          (ast, {s with error = Some "found no pos"}) )
    | FluidKeyPress {key; metaKey; ctrlKey}
      when (metaKey || ctrlKey) && shouldDoDefaultAction key ->
        (* To make sure no letters are entered if user is doing a browser default action *)
        (ast, s)
    | FluidKeyPress {key} ->
        let s = {s with lastKey = key} in
        updateKey key ast s
    | _ ->
        (ast, s)
  in
  let newState = updateAutocomplete m tlid newAST newState in
  (* Js.log2 "ast" (show_ast newAST) ; *)
  (* Js.log2 "tokens" (eToStructure s newAST) ; *)
  (newAST, newState)


let update (m : Types.model) (msg : Types.msg) : Types.modification =
  let s = m.fluidState in
  let s = {s with error = None; oldPos = s.newPos; actions = []} in
  match msg with
  | FluidKeyPress {key; metaKey; ctrlKey; shiftKey}
    when (metaKey || ctrlKey) && key = K.Letter 'z' ->
      KeyPress.undo_redo m shiftKey
  | FluidKeyPress {key; metaKey; ctrlKey; shiftKey}
    when (metaKey || ctrlKey) && key = K.Letter 'z' ->
      KeyPress.undo_redo m shiftKey
  | FluidKeyPress {key; altKey} when altKey && key = K.Letter 'x' ->
      maybeOpenCmd m
  | FluidKeyPress ke when m.fluidState.cp.show = true ->
      FluidCommands.updateCmds m ke
  | _ ->
    ( match Toplevel.selected m with
    | None ->
        Types.NoChange
    | Some tl ->
      ( match TL.rootExpr tl with
      | None ->
          NoChange
      | Some ast ->
          let ast = ast |> fromExpr s in
          let newAST, newState = updateMsg m tl.id ast msg s in
          let eventSpecMod, newAST, newState =
            let enter tl id = Enter (Filling (tl.id, id)) in
            (* if tab is wrapping... *)
            if newState.lastKey = K.Tab && newState.newPos <= newState.oldPos
            then
              (* toggle through spec headers *)
              (* if on first spec header that is blank
               * set cursor to select that *)
              match tl.data with
              | TLHandler {spec = {name = Blank id; _}; _} ->
                  (enter tl id, ast, s)
              | TLHandler {spec = {module_ = Blank id; _}; _} ->
                  (enter tl id, ast, s)
              | TLHandler {spec = {modifier = Blank id; _}; _} ->
                  (enter tl id, ast, s)
              | _ ->
                  (NoChange, newAST, newState)
            else (NoChange, newAST, newState)
            (* the above logic is slightly duplicated from Selection.toggleBlankTypes *)
          in
          let cmd =
            let astCmd =
              if newAST <> ast || newState.oldPos <> newState.newPos
              then [Entry.setBrowserPos newState.newPos]
              else []
            in
            let acCmd =
              match newState.ac.index with
              | Some index ->
                  [FluidAutocomplete.focusItem index]
              | None ->
                  []
            in
            let commands = acCmd @ astCmd in
            if List.isEmpty commands then Cmd.none else Cmd.batch commands
          in
          let astMod =
            if ast <> newAST
            then
              let asExpr = toExpr newAST in
              let requestAnalysis =
                match Analysis.cursor m tl.id with
                | Some traceID ->
                    let m = TL.withAST m tl.id asExpr in
                    MakeCmd (Analysis.requestAnalysis m tl.id traceID)
                | None ->
                    NoChange
              in
              Many
                [ Types.TweakModel (fun m -> TL.withAST m tl.id asExpr)
                ; Toplevel.setSelectedAST m asExpr
                ; requestAnalysis ]
            else Types.NoChange
          in
          Types.Many
            [ Types.TweakModel (fun m -> {m with fluidState = newState})
            ; astMod
            ; eventSpecMod
            ; Types.MakeCmd cmd ] ) )


(* -------------------- *)
(* View *)
(* -------------------- *)
let viewAutocomplete (ac : Types.fluidAutocompleteState) : Types.msg Html.html
    =
  let toList acis class' index =
    List.indexedMap
      ~f:(fun i item ->
        let highlighted = index = i in
        let name = AC.asName item in
        Html.li
          [ Attrs.classList
              [ ("autocomplete-item", true)
              ; ("fluid-selected", highlighted)
              ; (class', true) ]
          ; ViewUtils.nothingMouseEvent "mouseup"
          ; ViewEntry.defaultPasteHandler
          ; ViewUtils.nothingMouseEvent "mousedown"
          ; ViewUtils.eventNoPropagation ~key:("ac-" ^ name) "click" (fun _ ->
                AutocompleteClick name ) ]
          [ Html.text name
          ; Html.span [Html.class' "types"] [Html.text <| AC.asTypeString item]
          ] )
      acis
  in
  let index = ac.index |> Option.withDefault ~default:(-1) in
  let invalidIndex = index - List.length ac.completions in
  let autocompleteList =
    toList ac.completions "valid" index
    @ toList ac.invalidCompletions "invalid" invalidIndex
  in
  Html.div [Attrs.id "fluid-dropdown"] [Html.ul [] autocompleteList]


let viewCopyButton tlid value : msg Html.html =
  Html.div
    [ Html.class' "copy-value"
    ; Html.title "Copy this expression's value to the clipboard"
    ; ViewUtils.eventNoPropagation
        "click"
        ~key:("copylivevalue-" ^ showTLID tlid)
        (fun _ -> ClipboardCopyLivevalue value) ]
    [ViewUtils.fontAwesome "copy"]


let viewErrorIndicator ~tlid ~currentResults ~state ti : Types.msg Html.html =
  let returnTipe name =
    let fn = Functions.findByNameInList name state.ac.functions in
    Runtime.tipe2str fn.fnReturnTipe
  in
  let sentToRail id =
    let dv =
      StrDict.get ~key:(deID id) currentResults.liveValues
      |> Option.withDefault ~default:DNull
    in
    match dv with
    | DErrorRail (DResult (ResError _)) | DErrorRail (DOption OptNothing) ->
        "ErrorRail"
    | DIncomplete | DError _ ->
        "EvalFail"
    | _ ->
        ""
  in
  match ti.token with
  | TFnName (id, name, Rail) ->
      let offset = string_of_int ti.startRow ^ "rem" in
      let cls = ["error-indicator"; returnTipe name; sentToRail id] in
      Html.div
        [ Html.class' (String.join ~sep:" " cls)
        ; Html.styles [("top", offset)]
        ; ViewUtils.eventNoPropagation
            ~key:("er-" ^ show_id id)
            "click"
            (fun _ -> TakeOffErrorRail (tlid, id)) ]
        []
  | _ ->
      Vdom.noNode


let viewPlayIcon
    ~tlid
    ~currentResults
    ~executingFunctions
    ~state
    (ast : ast)
    (ti : tokenInfo) : Types.msg Html.html =
  match ti.token with
  | TFnName (id, name, _) ->
      let fn = Functions.findByNameInList name state.ac.functions in
      let previous =
        ast
        |> toExpr
        |> AST.threadPrevious id
        |> Option.toList
        |> List.map ~f:(fromExpr state)
      in
      let exprs =
        match findExpr id ast with
        | Some (EFnCall (id, name, exprs, _)) when id = id && name = name ->
            exprs
        | _ ->
            []
      in
      (* buttons *)
      let allExprs = previous @ exprs in
      let isComplete id =
        id
        |> ViewBlankOr.getLiveValue currentResults.liveValues
        |> fun v ->
        match v with
        | None | Some (DError _) | Some DIncomplete ->
            false
        | Some _ ->
            true
      in
      let paramsComplete = List.all ~f:(isComplete << eid) allExprs in
      let buttonUnavailable = not paramsComplete in
      let showButton = not fn.fnPreviewExecutionSafe in
      let buttonNeeded = not (isComplete id) in
      let exeIcon = "play" in
      let events =
        [ ViewUtils.eventNoPropagation
            ~key:("efb-" ^ showTLID tlid ^ "-" ^ showID id ^ "-" ^ name)
            "click"
            (fun _ -> ExecuteFunctionButton (tlid, id, name))
        ; ViewUtils.nothingMouseEvent "mouseup"
        ; ViewUtils.nothingMouseEvent "mousedown"
        ; ViewUtils.nothingMouseEvent "dblclick" ]
      in
      let class_, event, title, icon =
        if name = "Password::check" || name = "Password::hash"
        then
          ( "execution-button-unsafe"
          , []
          , "Cannot run interactively for security reasons."
          , "times" )
        else if buttonUnavailable
        then
          ( "execution-button-unavailable"
          , []
          , "Cannot run: some parameters are incomplete"
          , exeIcon )
        else if buttonNeeded
        then
          ( "execution-button-needed"
          , events
          , "Click to execute function"
          , exeIcon )
        else
          ( "execution-button-repeat"
          , events
          , "Click to execute function again"
          , "redo" )
      in
      let executingClass =
        if List.member ~value:id executingFunctions then "is-executing" else ""
      in
      if not showButton
      then Vdom.noNode
      else
        Html.div
          ( [ Html.class' ("execution-button " ^ class_ ^ executingClass)
            ; Html.title title ]
          @ event )
          [ViewUtils.fontAwesome icon]
  | _ ->
      Vdom.noNode


let toHtml ~tlid ~currentResults ~executingFunctions ~state (ast : ast) :
    Types.msg Html.html list =
  let l = ast |> toTokens state in
  List.map l ~f:(fun ti ->
      let dropdown () =
        if state.cp.show && Some (Token.tid ti.token) = state.cp.cmdOnID
        then FluidCommands.viewCommandPalette state.cp
        else if isAutocompleting ti state
        then viewAutocomplete state.ac
        else Vdom.noNode
      in
      let element nested =
        let content = Token.toText ti.token in
        let classes = Token.toCssClasses ti.token in
        let idclasses = ["id-" ^ deID (Token.tid ti.token)] in
        Html.span
          [ Attrs.class'
              (["fluid-entry"] @ classes @ idclasses |> String.join ~sep:" ")
          ]
          ([Html.text content] @ nested)
      in
      [ element
          [ dropdown ()
          ; ti
            |> viewPlayIcon
                 ~tlid
                 ~currentResults
                 ~executingFunctions
                 ~state
                 ast ] ] )
  |> List.flatten


let viewLiveValue ~tlid ~currentResults ~state (tis : tokenInfo list) :
    Types.msg Html.html =
  let liveValues, show, offset =
    getLeftTokenAt state.newPos tis
    |> Option.andThen ~f:(fun ti ->
           match ti.token with
           | TSep | TNewline | TIndented _ | TIndent _ | TIndentToHere _ ->
               None
           | _ ->
               let liveValuesOfToken =
                 let id = Token.tid ti.token in
                 let liveValueString =
                   StrDict.get ~key:(deID id) currentResults.liveValues
                   |> Option.map ~f:Runtime.toRepr
                   |> Option.withDefault ~default:"<loading>"
                 in
                 [ Html.text liveValueString
                 ; viewCopyButton tlid liveValueString ]
               in
               Some (liveValuesOfToken, true, ti.startRow) )
    |> Option.withDefault ~default:([Vdom.noNode], false, 0)
  in
  let offset = float_of_int offset +. 1.5 in
  Html.div
    [ Html.classList [("live-values", true); ("show", show)]
    ; Html.styles [("top", Js.Float.toString offset ^ "rem")]
    ; Attrs.autofocus false
    ; Attrs.spellcheck false ]
    liveValues


let viewAST
    ~(tlid : tlid)
    ~(currentResults : analysisResults)
    ~(executingFunctions : id list)
    ~(state : state)
    (ast : ast) : Types.msg Html.html list =
  let cmdOpen = FluidCommands.isOpenOnTL state.cp tlid in
  let event ~(key : string) (event : string) : Types.msg Vdom.property =
    let decodeNothing =
      let open Tea.Json.Decoder in
      succeed Types.IgnoreMsg
    in
    (* There is a check to preventDefault() in the appsupport file *)
    Html.on ~key event decodeNothing
  in
  let eventKey = "keydown" ^ show_tlid tlid ^ string_of_bool cmdOpen in
  let tokenInfos = ast |> toTokens state in
  let errorRail =
    let indicators =
      tokenInfos
      |> List.map ~f:(fun ti ->
             viewErrorIndicator ~tlid ~currentResults ~state ti )
    in
    let hasMaybeErrors = List.any ~f:(fun e -> e <> Vdom.noNode) indicators in
    Html.div
      [Html.classList [("fluid-error-rail", true); ("show", hasMaybeErrors)]]
      indicators
  in
  [ tokenInfos |> viewLiveValue ~tlid ~currentResults ~state
  ; Html.div
      [ Attrs.id editorID
      ; Vdom.prop "contentEditable" "true"
      ; Attrs.autofocus true
      ; Attrs.spellcheck false
      ; event ~key:eventKey "keydown" ]
      (ast |> toHtml ~tlid ~currentResults ~executingFunctions ~state)
  ; errorRail ]


let viewStatus (ast : ast) (s : state) : Types.msg Html.html =
  let tokens = toTokens s ast in
  let posDiv =
    let oldGrid = gridFor ~pos:s.oldPos tokens in
    let newGrid = gridFor ~pos:s.newPos tokens in
    [ Html.div
        []
        [ Html.text (string_of_int s.oldPos)
        ; Html.text " -> "
        ; Html.text (string_of_int s.newPos) ]
    ; Html.div
        []
        [ Html.text (oldGrid.col |> string_of_int)
        ; Html.text ","
        ; Html.text (oldGrid.row |> string_of_int)
        ; Html.text " -> "
        ; Html.text (newGrid.col |> string_of_int)
        ; Html.text ","
        ; Html.text (newGrid.row |> string_of_int) ]
    ; Html.div
        []
        [ Html.text "acIndex: "
        ; Html.text
            ( s.ac.index
            |> Option.map ~f:string_of_int
            |> Option.withDefault ~default:"None" ) ]
    ; Html.div
        []
        [ Html.text "lastKey: "
        ; Html.text
            ( K.toName s.lastKey
            ^ ", "
            ^ ( K.toChar s.lastKey
              |> Option.map ~f:String.fromChar
              |> Option.withDefault ~default:"" ) ) ] ]
  in
  let tokenDiv =
    let prev, current, next = getTokensAtPosition tokens ~pos:s.newPos in
    let p =
      match prev with Some prev -> Token.show_tokenInfo prev | None -> "none"
    in
    let c =
      match current with
      | Some current ->
          Token.show_tokenInfo current
      | None ->
          "none"
    in
    let n =
      match next with Some next -> Token.show_tokenInfo next | None -> "none"
    in
    [ Html.text ("prev: " ^ p)
    ; Html.br []
    ; Html.text ("current: " ^ c)
    ; Html.br []
    ; Html.text ("next: " ^ n) ]
  in
  let actions =
    [ Html.div
        []
        ( [Html.text "Actions: "]
        @ ( s.actions
          |> List.map ~f:(fun action -> [action; ", "])
          |> List.concat
          |> List.dropRight ~count:1
          |> List.map ~f:Html.text ) ) ]
  in
  let error =
    [ Html.div
        []
        [ Html.text
            ( Option.map s.error ~f:(fun e -> "Errors: " ^ e)
            |> Option.withDefault ~default:"none" ) ] ]
  in
  let status = List.concat [posDiv; tokenDiv; actions; error] in
  Html.div [Attrs.id "fluid-status"] status

(* -------------------- *)
(* Scaffolidng *)
(* -------------------- *)

(* let registerGlobalDirect name tagger = *)
(*   let open Vdom in *)
(*   let enableCall callbacks_base = *)
(*     let callbacks = ref callbacks_base in *)
(*     let fn ev = Some (tagger (Obj.magic ev)) in *)
(*     let handler = EventHandlerCallback (name, fn) in *)
(*     let elem = Web_node.document_node in *)
(*     let cache = eventHandler_Register callbacks elem name handler in *)
(*     fun () -> ignore (eventHandler_Unregister elem name cache) *)
(*   in *)
(*   Tea_sub.registration name enableCall *)
(*  *)

(* let subscriptions (_m : model) : msg Tea.Sub.t = *)
(*   let keySubs = [Keyboard.downs (fun x -> KeyPress x)] in *)
(*   let mouseSubs = [Mouse.ups (fun _ -> MouseClick)] in *)
(*   let events = [registerGlobalDirect "SaveEditor" (fun _ -> SaveEditor)] in *)
(*   Tea.Sub.batch (List.concat [keySubs; mouseSubs; events]) *)
(*  *)
