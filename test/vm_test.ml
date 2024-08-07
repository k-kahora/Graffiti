open Object

let parse input = Lex.new' input |> Parsing.new_parser |> Parsing.parse_program

let ( let* ) = Result.bind

type vm_test_type = Int of int | Bool of bool

let compare_test_type t1 t2 = t1 = t2

let pp_test_type fmt test_type =
  let format_helper = Format.fprintf in
  match test_type with
  | Int a ->
      format_helper fmt "%d" a
  | Bool a ->
      format_helper fmt "%b" a

let alcotest_test_type = Alcotest.testable pp_test_type compare_test_type

let test_expected_object actual =
  match actual with
  | Obj.Int value2 ->
      Ok (Int value2)
  | Obj.Bool value2 ->
      Ok (Bool value2)
  | obj ->
      Error (Code.CodeError.ObjectNotImplemented obj)

(* FIXME incorrect use of let* *)
let setup_vm_test input =
  let program = parse input in
  let comp = Compiler.new_compiler in
  let* comp = Compiler.compile program.statements comp in
  let vm = Vm.new_virtual_machine comp in
  let* res = Vm.run vm in
  let stack_elem = res.last_item_poped in
  test_expected_object stack_elem

let run_vm_tests (input, expected) =
  let result = setup_vm_test input in
  Alcotest.(check (result alcotest_test_type Code.CodeError.alcotest_error))
    "Checking result " expected result

let test_bool_expressions () =
  let tests =
    [("true", true); ("false", false)]
    |> List.map (fun (a, b) -> (a, Ok (Bool b)))
  in
  List.iter run_vm_tests tests

let test_int_arithmatic () =
  let tests =
    [ ("1 - 2", -1)
    ; ("1 * 2", 2)
    ; ("4 / 2", 2)
    ; ("50 / 2 * 2 + 10 - 5", 55)
    ; ("5 + 5 + 5 + 5 - 10", 10)
    ; ("2 * 2 * 2 * 2 * 2", 32)
    ; ("5 * 2 + 10", 20)
    ; ("5 + 2 * 10", 25)
    ; ("5 * (2 + 10)", 60) ]
    |> List.map (fun (a, b) -> (a, Ok (Int b)))
  in
  List.iter run_vm_tests tests

let () =
  Alcotest.run "Virtual Machine Tests"
    [ ( "Arithmatic"
      , [Alcotest.test_case "int arithmetic" `Quick test_int_arithmatic] )
    ; ( "Booleans"
      , [ Alcotest.test_case "boolean expressions vm" `Quick
            test_bool_expressions ] ) ]
