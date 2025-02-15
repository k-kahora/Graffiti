let ( let* ) = Result.bind

type parser =
  { l: Lex.lexer
  ; curToken: Token.token
  ; peekToken: Token.token
  ; prefixParseFns: (Token.token_name, prefixParseFn) Utils.Token_AssocList.t
  ; infinxParseFns: (Token.token_name, infixParseFn) Utils.Token_AssocList.t
  ; errors: string list }

and prefixParseFn = parser -> (Ast.expression * parser, string) result

and infixParseFn =
  parser -> Ast.expression -> (Ast.expression * parser, string) result

type precedence =
  | LOWEST
  | EQUALS (* == *)
  | LESSGREATER (* < or > *)
  | SUM (* + *)
  | PRODUCT (* * *)
  | PREFIX (* -X or !X *)
  | CALL (* func(X) *)
  | INDEX

let precedences =
  Utils.Token_AssocList.(
    empty |> add Token.EQ EQUALS |> add Token.NOT_EQ EQUALS
    |> add Token.LT LESSGREATER |> add Token.GT LESSGREATER
    |> add Token.GTEQ LESSGREATER |> add Token.LTEQ LESSGREATER
    |> add Token.PLUS SUM |> add Token.MINUS SUM |> add Token.SLASH PRODUCT
    |> add Token.ASTERISK PRODUCT |> add Token.LPAREN CALL
    |> add Token.LBRACKET INDEX )

let precedence_level (p : precedence) =
  match p with
  | LOWEST ->
      0
  | EQUALS ->
      1
  | LESSGREATER ->
      2
  | SUM ->
      3
  | PRODUCT ->
      4
  | PREFIX ->
      5
  | CALL ->
      6
  | INDEX ->
      6

let cur_precedence (p : parser) : precedence =
  match Utils.Token_AssocList.find p.curToken.type' precedences with
  | Some pr ->
      pr
  | None ->
      LOWEST

let peek_precedence (p : parser) : precedence =
  match Utils.Token_AssocList.find p.peekToken.type' precedences with
  | Some pr ->
      pr
  | None ->
      LOWEST

let register_infix (p : parser) ~(t : Token.token_name) ~(fn : infixParseFn) :
    parser =
  {p with infinxParseFns= Utils.Token_AssocList.add t fn p.infinxParseFns}

let register_prefix (p : parser) ~(t : Token.token_name) ~(fn : prefixParseFn) :
    parser =
  {p with prefixParseFns= Utils.Token_AssocList.add t fn p.prefixParseFns}

let errors (p : parser) : string list = p.errors

let check_error_bind a = match a with Ok p -> p | Error e -> failwith e

let check_error a = match a with Ok _ -> a | Error e -> failwith e

let peek_error (p : parser) (t : Token.token_name) : string =
  let msg =
    Format.sprintf "expected next token to be %s got %s instead"
      (Token.token_to_string_debug t)
      (Token.token_to_string_debug p.peekToken.type')
  in
  msg
(* HACK Anti pattern copies the whole list each time*)

let print_parser (p : parser) : unit =
  Format.printf "Current Token: %s \n"
    (Token.token_to_string_debug p.curToken.type') ;
  Format.printf "Peek token: %s \n"
    (Token.token_to_string_debug p.peekToken.type')

let next_token (p : parser) : parser =
  let nextToken, l = Lex.next_token p.l in
  (* Format.printf "Next Token: %s \n" *)
  (* Token.token_to_string_debug nextToken.type' ; *)
  {p with curToken= p.peekToken; peekToken= nextToken; l}

(* TODO trace through 1 + 2 * 3 to understand operator precedenc *)
let parse_expression (precedence' : precedence) (p : parser) :
    (Ast.expression * parser, string) result =
  let* prefix =
    match Utils.Token_AssocList.find p.curToken.type' p.prefixParseFns with
    | Some pre ->
        Ok pre
    | None ->
        Error
          ( "No prefix parse function registed for "
          ^ Token.token_to_string_debug p.curToken.type'
          ^ " operator" )
  in
  let* left_exp, p = prefix p in
  (* Loop while the peekToken is not a semicolon and the precedence is less than the peek precedenc *)
  let rec loop left_e p =
    match p.curToken.type' with
    | Token.SEMICOLON ->
        Ok (left_e, p)
    | _
      when precedence_level precedence' < precedence_level @@ peek_precedence p
      -> (
      match Utils.Token_AssocList.find p.peekToken.type' p.infinxParseFns with
      | Some infix ->
          (* NOTE this is where the magic happens *)
          (* for 1 + 2 + 3 this returns [Ast.InfixExpression (1 + 2)] for exp*)
          (* This is where less precedenc expressions get sucked into the left arm *)
          (* FIXME this is a critcal moment in the parser make that more clear *)
          let* exp, p = infix (next_token p) left_e in
          loop exp p
      | None ->
          Ok (left_e, p) )
    | _ ->
        (* This is triggered for right binding No expression will be put into a left arm if this match statement is trigged *)
        Ok (left_e, p)
  in
  loop left_exp p

let cur_token_is (p : parser) (t : Token.token_name) : bool =
  p.curToken.type' = t

let peek_token_is (p : parser) (t : Token.token_name) : bool =
  p.peekToken.type' = t

let expect_peek (p : parser) (t : Token.token_name) : (parser, string) result =
  let b = peek_token_is p t in
  if b then Ok (next_token p) else Error (peek_error p t)

let parse_bool (p : parser) : (Ast.expression * parser, string) result =
  Ok
    ( Ast.BooleanExpression {token= p.curToken; value= cur_token_is p Token.TRUE}
    , p )

let parse_string_literal p =
  Ok (Ast.StringLiteral {token= p.curToken; value= p.curToken.literal}, p)

let parse_integer_literal (p : parser) :
    (Ast.expression * parser, string) result =
  Ok
    ( Ast.IntegerLiteral
        {token= p.curToken; value= int_of_string p.curToken.literal}
    , p )

(* let lit = int_of_string p.curToken.literal in *)

let parse_prefix_expression (p : parser) :
    (Ast.expression * parser, string) result =
  let* expression, new_p = next_token p |> parse_expression PREFIX in
  Ok
    ( Ast.PrefixExpression
        {token= p.curToken; operator= p.curToken.literal; right= expression}
    , new_p )

let parse_identifier (p : parser) : (Ast.expression * parser, string) result =
  Ok (Ast.Identifier {token= p.curToken; value= p.curToken.literal}, p)

let parse_group_expression p =
  (* Advance the parser by one after a LPAREN parse the entire expression *)
  let* exp, new_p = next_token p |> parse_expression LOWEST in
  let open Result in
  let ( >>= ) = bind in
  (* After the expression has been parsed there better be a Right paren *)
  let* next_tkn_parser = Ok new_p >>= fun ft -> expect_peek ft Token.RPAREN in
  Ok (exp, next_tkn_parser)

let parse_infix_expression (p : parser) (left_exp : Ast.expression) :
    (Ast.expression * parser, string) result =
  let* right_exp, new_p = next_token p |> parse_expression (cur_precedence p) in
  Ok
    ( Ast.InfixExpression
        { left= left_exp
        ; token= p.curToken
        ; operator= p.curToken.literal
        ; right= right_exp }
    , new_p )

let rec parse_statement (p : parser) : (Ast.statement * parser, string) result =
  match p.curToken.type' with
  | Token.LET ->
      parse_let_statement p
  | Token.RETURN ->
      parse_return_statement p
  | _ ->
      parse_expression_statement p

and parse_let_statement (p : parser) : (Ast.statement * parser, string) result =
  let open Result in
  let ( >>= ) = bind in
  (* First check for the ident token *)
  let* last_token =
    Ok p >>= fun ft -> expect_peek ft Token.IDENT |> check_error
  in
  (* Set statement name = to the current token *)
  let ident =
    Ast.Identifier
      {token= last_token.curToken; value= last_token.curToken.literal}
  in
  (* check for the ASSIGN token *)
  let* last_token =
    Ok last_token >>= fun nt -> expect_peek nt Token.ASSIGN |> check_error
  in
  let* value, n_p = parse_expression LOWEST (next_token last_token) in
  let value =
    match value with
    | Ast.FunctionLiteral func ->
        (* NOTE this will never error *)
        let name = Ast.get_ident ident |> Option.get in
        Ast.FunctionLiteral {func with name}
    | _ ->
        value
  in
  let n_p = if peek_token_is n_p Token.SEMICOLON then next_token n_p else n_p in
  Ok (Ast.Letstatement {name= ident; token= p.curToken; value}, n_p)

(* Ast.new_let_satement () *)
and parse_return_statement (p : parser) :
    (Ast.statement * parser, string) result =
  let n_p = next_token p in
  let* exp, n_p = parse_expression LOWEST n_p in
  let return = Ast.Returnstatement {token= p.curToken; return_value= exp} in
  let n_p = if peek_token_is n_p Token.SEMICOLON then next_token n_p else n_p in
  Ok (return, n_p)

and parse_expression_statement p =
  let* expr, p = parse_expression LOWEST p in
  let stmt =
    let tok = {Token.type'= Token.ILLEGAL; literal= "null"} in
    Ast.Expressionstatement {token= tok; expression= (*NOTE ==> *) expr}
  in
  let p = if peek_token_is p Token.SEMICOLON then next_token p else p in
  (* Skip semeicolons*)
  Ok (stmt, p)

let parse_block (p : parser) : (Ast.block * parser, string) result =
  (* Loop whle the cur token is not a RBRACE or EOF *)
  let rec looper p acc =
    match p.curToken.type' with
    | Token.RBRACE | Token.EOF ->
        Ok (acc, p)
    | _ ->
        let* stmt, new_p = parse_statement p in
        (looper [@tailcall]) (next_token new_p) (stmt :: acc)
  in
  let* st, new_p = looper (next_token p) [] in
  Ok ({Ast.statements= List.rev st; token= p.curToken}, new_p)

let parse_if_expression (p : parser) : (Ast.expression * parser, string) result
    =
  (* condition, alterntive; consequence; token *)
  let open Result in
  let ( >>= ) = bind in
  (* NOTE check next token for a LPAREN *)
  let* paren_parse = Ok p >>= fun ft -> expect_peek ft Token.LPAREN in
  (* NOTE advance the parser and set the condition equal to the expression *)
  let* cond, new_p = paren_parse |> next_token |> parse_expression LOWEST in
  (* NOTE check for a consequence and an ealterntive *)
  let* n_parse =
    Ok new_p
    >>= fun ft ->
    expect_peek ft Token.RPAREN >>= fun fn -> expect_peek fn Token.LBRACE
  in
  let* cons, new_p = n_parse |> parse_block in
  match new_p.peekToken.type' with
  | Token.ELSE -> (
      let new_p = next_token new_p in
      let monad_p = Ok new_p >>= fun ft -> expect_peek ft Token.LBRACE in
      match monad_p with
      | Ok np ->
          let* block, new_p = parse_block np in
          Ok
            ( Ast.IfExpression
                { token= p.curToken
                ; consquence= Ast.BlockStatement cons
                ; altenative= Some (Ast.BlockStatement block)
                ; condition= cond }
            , new_p )
      | Error e ->
          failwith ("error is -> " ^ e ^ "\n") )
  | _ ->
      Ok
        ( Ast.IfExpression
            { token= p.curToken
            ; consquence= Ast.BlockStatement cons
            ; altenative= None
            ; condition= cond }
        , new_p )

let parse_function_parameters p =
  (* TODO make tail recursive *)
  let loop_through_params p =
    let ident = Ast.Identifier {token= p.curToken; value= p.curToken.literal} in
    let acc = [ident] in
    let rec helper acc p =
      match p.peekToken.type' with
      | Token.COMMA ->
          let new_p = next_token p |> next_token in
          helper
            ( Ast.Identifier
                {token= new_p.curToken; value= new_p.curToken.literal}
            :: acc )
            new_p
      | _ ->
          (acc, p)
    in
    let contents, par = helper acc p in
    (* token check *)
    let open Result in
    let ( >>= ) = bind in
    let inter =
      let inte = Ok par >>= fun ft -> expect_peek ft Token.RPAREN in
      match inte with
      | Error _ ->
          failwith "invalid syntax needs to end in a RPAREN"
      | Ok l ->
          l
    in
    (List.rev contents, inter)
  in
  if peek_token_is p Token.RPAREN then ([], next_token p)
  else loop_through_params (next_token p)

let parse_function_literal p =
  let open Result in
  let ( >>= ) = bind in
  let n_p =
    let intermediate = Ok p >>= fun ft -> expect_peek ft Token.LPAREN in
    match intermediate with Error _e -> failwith "failed" | Ok l -> l
  in
  let parameters, n_p = parse_function_parameters n_p in
  let n_p =
    let intermediate = Ok n_p >>= fun ft -> expect_peek ft Token.LBRACE in
    match intermediate with Error _e -> failwith "invalide syntax" | Ok r -> r
  in
  let* body_block, n_p = parse_block n_p in
  Ok
    ( Ast.FunctionLiteral
        { name= "blank"
        ; token= p.curToken
        ; body= Ast.BlockStatement body_block
        ; parameters }
    , n_p )

let parse_expression_list (token_end : Token.token_name) (p : parser) =
  let open Result in
  let ( >>= ) = bind in
  let looper p =
    (* FIXME uneccesay line just gets the loop running *)
    let* exp, new_p = next_token p |> parse_expression LOWEST in
    let rec helper p acc =
      match p.peekToken.type' with
      | Token.COMMA ->
          let* exp, new_p =
            next_token p |> next_token |> parse_expression LOWEST
          in
          helper new_p (exp :: acc)
      | tk when token_end = tk ->
          Ok (acc, p)
      | tk ->
          Error
            (Format.sprintf "Expected ',' got %s" (Token.token_to_string tk))
    in
    let* args, n_p = helper new_p [exp] in
    let pars =
      let closing_token = Ok n_p >>= fun ft -> expect_peek ft token_end in
      match closing_token with
      | Error _ ->
          failwith "invalid syntax needs to end in a RPAREN"
      | Ok l ->
          l
    in
    Ok (List.rev args, pars)
  in
  if peek_token_is p token_end then Ok ([], next_token p) else looper p

let parse_call_expression p func =
  let* elements, new_p = parse_expression_list Token.RPAREN p in
  Ok (Ast.CallExpression {token= p.curToken; arguments= elements; func}, new_p)

let parse_array_literal p =
  let* elements, new_p = parse_expression_list Token.RBRACKET p in
  Ok (Ast.ArrayLiteral {token= p.curToken; elements}, new_p)

let parse_index_expression p left =
  let* idx, new_p = next_token p |> parse_expression LOWEST in
  let open Result in
  let ( >>= ) = bind in
  let* next_token = Ok new_p >>= fun ft -> expect_peek ft Token.RBRACKET in
  Ok (Ast.IndexExpression {token= p.curToken; left; index= idx}, next_token)

let parse_hash_literal p =
  let open Result in
  let ( >>= ) = bind in
  let hash = Hashtbl.create 1838 in
  let rec helper p =
    match p.peekToken.type' with
    | Token.RBRACE ->
        Ok p
    | _ ->
        let* key, new_p = next_token p |> parse_expression LOWEST in
        let n_token =
          Ok new_p
          >>= (fun ft -> expect_peek ft Token.COLON)
          |> check_error_bind |> next_token
        in
        let* value, new_p = parse_expression LOWEST n_token in
        Hashtbl.add hash key value ;
        if not @@ peek_token_is new_p Token.RBRACE then
          let n_p =
            Ok new_p
            >>= (fun ft -> expect_peek ft Token.COMMA)
            |> check_error_bind
          in
          helper n_p
        else helper new_p
  in
  let* n_p = helper p in
  let* n_token = Ok n_p >>= fun ft -> expect_peek ft Token.RBRACE in
  Ok (Ast.HashLiteral {token= p.curToken; pairs= hash}, n_token)

let new_parser (l : Lex.lexer) : parser =
  let curToken, cur = Lex.next_token l in
  let peekToken, l = Lex.next_token cur in
  { l
  ; curToken
  ; peekToken
  ; errors= []
  ; prefixParseFns= Utils.Token_AssocList.empty
  ; infinxParseFns= Utils.Token_AssocList.empty }
  |> register_prefix ~t:Token.IDENT ~fn:parse_identifier
  |> register_prefix ~t:Token.INT ~fn:parse_integer_literal
  |> register_prefix ~t:Token.STRING ~fn:parse_string_literal
  |> register_prefix ~t:Token.BANG ~fn:parse_prefix_expression
  |> register_prefix ~t:Token.MINUS ~fn:parse_prefix_expression
  |> register_prefix ~t:Token.TRUE ~fn:parse_bool
  |> register_prefix ~t:Token.FALSE ~fn:parse_bool
  |> register_prefix ~t:Token.LPAREN ~fn:parse_group_expression
  |> register_prefix ~t:Token.LBRACKET ~fn:parse_array_literal
  |> register_prefix ~t:Token.IF ~fn:parse_if_expression
  |> register_prefix ~t:Token.FUNCTION ~fn:parse_function_literal
  |> register_prefix ~t:Token.LBRACE ~fn:parse_hash_literal
  |> register_infix ~t:Token.PLUS ~fn:parse_infix_expression
  |> register_infix ~t:Token.MINUS ~fn:parse_infix_expression
  |> register_infix ~t:Token.SLASH ~fn:parse_infix_expression
  |> register_infix ~t:Token.ASTERISK ~fn:parse_infix_expression
  |> register_infix ~t:Token.EQ ~fn:parse_infix_expression
  |> register_infix ~t:Token.NOT_EQ ~fn:parse_infix_expression
  |> register_infix ~t:Token.LT ~fn:parse_infix_expression
  |> register_infix ~t:Token.GT ~fn:parse_infix_expression
  |> register_infix ~t:Token.GTEQ ~fn:parse_infix_expression
  |> register_infix ~t:Token.LTEQ ~fn:parse_infix_expression
  |> register_infix ~t:Token.LPAREN ~fn:parse_call_expression
  |> register_infix ~t:Token.LBRACKET ~fn:parse_index_expression

module type Monad = sig
  type 'a t

  val return : 'a -> 'a t

  val ( >>= ) : 'a t -> ('a -> 'b t) -> 'b t
end

module Maybe : Monad = struct
  type 'a t = 'a option

  let return x = Some x

  let ( >>= ) m f = match m with None -> None | Some x -> f x
end

(* all the bindings will fail if the incorrect token is found *)

(* See if a parsing function is associated with the token and call that function *)

(* This program is kept to work with the legacy tests, nightmare refractoring *)
let parse_program (p : parser) : Ast.program =
  (* Parse each token until there is a EOF token *)
  let rec looper acc p =
    match p.curToken.type' with
    | Token.EOF ->
        acc
    | _ -> (
      match parse_statement p with
      | Error _err ->
          failwith "The global ERROR"
      | Ok (stmt, p) ->
          looper (stmt :: acc) (next_token p) )
  in
  let d_stms = looper [] p in
  {Ast.statements= List.rev d_stms}

let parse_program_result p =
  (* Parse each token until there is a EOF token *)
  let rec looper acc p =
    match p.curToken.type' with
    | Token.EOF ->
        Ok acc
    | _ -> (
      match parse_statement p with
      | Error err ->
          Error err
      | Ok (stmt, p) ->
          looper (stmt :: acc) (next_token p) )
  in
  let* d_stms = looper [] p in
  Ok {Ast.statements= List.rev d_stms}

(* FIXME reversing affects runtime  *)
(* List must be reversed due to the way is is handled by appending to the front *)
