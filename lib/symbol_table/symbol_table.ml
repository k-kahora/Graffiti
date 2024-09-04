let ( let* ) = Result.bind

type symbol_scope = GLOBAL | LOCAL | BUILTIN | FREE

let scope_to_string = function
  | GLOBAL ->
      "GLOBAL"
  | FREE ->
      "FREE"
  | LOCAL ->
      "LOCAL"
  | BUILTIN ->
      "BUILTIN"

type symbol = {name: string; scope: symbol_scope; index: int}

let symbol_eq s1 s2 = s1 = s2

let string_of_symbol symb =
  Format.sprintf "{name=%s; scope=%s; index=%d}" symb.name
    (scope_to_string symb.scope)
    symb.index

let string_of_store _symb = Format.sprintf ""

let symbol_pp fmt symb = Format.fprintf fmt "%s" (string_of_symbol symb)

let alc_symbol = Alcotest.testable symbol_pp symbol_eq

let n_symbol name scope index = {name; scope; index}

module StringMap = Map.Make (String)

type symbol_table =
  { mutable store: symbol StringMap.t
  ; num_definitions: int
  ; outer: symbol_table option
  ; mutable free_symbols: symbol list }

let define_builtin index name st =
  let symbol = {name; index; scope= BUILTIN} in
  let store = StringMap.add name symbol st.store in
  (symbol, {st with store})

let rec symbol_table_string symb_tb =
  Format.sprintf "{store=%s; num_definitions=%d; outer=%s; }"
    (string_of_store symb_tb.store)
    symb_tb.num_definitions
    (Option.fold ~none:"None" ~some:symbol_table_string symb_tb.outer)

let symbol_table_pp fmt symb_tb =
  Format.fprintf fmt "%s" (symbol_table_string symb_tb)

let symbol_table_eq st1 st2 = StringMap.equal ( = ) st1.store st2.store

let alc_symbol_table = Alcotest.testable symbol_table_pp symbol_table_eq

let new_symbol_table () =
  {store= StringMap.empty; num_definitions= 0; outer= None; free_symbols= []}

let new_enclosed_symbol_table symbol_table =
  { store= StringMap.empty
  ; num_definitions= 0
  ; outer= Some symbol_table
  ; free_symbols= [] }

let define_free original symbol_table =
  let free_symbols = symbol_table.free_symbols @ [original] in
  let symbol =
    n_symbol original.name FREE (List.length symbol_table.free_symbols)
  in
  let store = StringMap.add original.name symbol symbol_table.store in
  symbol_table.store <- store ;
  symbol_table.free_symbols <- free_symbols ;
  symbol

let define name st =
  let scope = Option.fold ~none:GLOBAL ~some:(fun _ -> LOCAL) st.outer in
  let symbol = n_symbol name scope st.num_definitions in
  let store = StringMap.add name symbol st.store in
  let symbol =
    ({st with num_definitions= st.num_definitions + 1; store}, symbol)
  in
  symbol

let resolve name st =
  let error = Code.CodeError.SymbolNotFound ("GLOBAL", name) in
  let rec resolve_helper outer_st =
    (* First if the outerscope is Null return an error  *)
    let* current_st = Option.to_result ~none:error outer_st in
    (* First if the outerscope is Null return an error  *)
    let found = StringMap.find_opt name current_st.store in
    (* If there is another outer scope and we did not find the object *)
    if Option.is_none found then resolve_helper current_st.outer
    else
      let symbol = Option.get found in
      match symbol.scope with
      | GLOBAL | BUILTIN ->
          Ok symbol
      | _ ->
          let free = define_free symbol current_st in
          print_endline "length" ;
          print_int (List.length current_st.free_symbols) ;
          print_endline "in free" ;
          Ok free
  in
  (* First we find if it is in the current scope if not we try to resolve it by moving up the scope *)
  StringMap.find_opt name st.store
  |> Option.fold ~none:(resolve_helper st.outer) ~some:Result.ok
(* |> Option.to_result *)
(*      ~none:(Code.CodeError.SymbolNotFound ("Global symbol not found", name)) *)
