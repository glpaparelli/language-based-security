type permission = Pread | Pwrite;;
module SS = Set.Make(struct type t = permission;; let compare = fun p1 p2 -> if p1 = p2 then 0 else 1 end);;

(* Elementary types *)
type expr =
  | EInt of int
  | EBool of bool
  | Var of string
  | Let of string * expr * expr
  | Prim of string * expr * expr
  | If of expr * expr * expr
  | Fun of string * expr * SS.t
  | Call of expr * expr
  | Read of string
  | Write of string
  | Open of string

(* Environment definition: association list, i.e., a list of pair (identifier, data) *)
type 'v env = (string * 'v) list

(* Runtime value definition (boolean are encoded as integers) *)
type value =
  | Int of int
  | Closure of string * expr * value env * SS.t

(* Function to return data bounded to {x} in the environment *)
let rec lookup env x =
  match env with
  | [] -> failwith (x ^ " not found")
  | (y, v) :: r -> if x = y then v else lookup r x

(* === Stack Inspection Implementation === *)
(* Are all permissions in {p_asked} also in every list of {p_stack}? *)
let rec stackInspection (p_asked : SS.t) (p_stack : SS.t list) =
  if SS.is_empty(p_asked) then
    true
  else match p_stack with
    | [] -> true
    | p_caller :: p_callers_tail -> 
      if SS.equal (SS.inter p_asked p_caller) p_asked then
        stackInspection p_asked p_callers_tail
      else 
        false

(* Interpreter *)
let rec eval expr env (p_stack : SS.t list) : value =
  match expr with
  | EInt n -> Int n
  | EBool n -> if n then Int 1 else Int 0
  | Var x -> lookup env x
  | If(e1, e2, e3) ->
    begin
      match eval e1 env p_stack with
      | Int 1 -> eval e2 env p_stack
      | Int 0 -> eval e3 env p_stack
      | _     -> failwith "Unexpected condition."
    end
  | Prim (op, e1, e2) ->
    let v1 = eval e1 env p_stack in
      let v2 = eval e2 env p_stack in
        begin
          match (op, v1, v2) with
            | "*", Int i1, Int i2 -> Int (i1 * i2)
            | "+", Int i1, Int i2 -> Int (i1 + i2)
            | "-", Int i1, Int i2 -> Int (i1 - i2)
            | "=", Int i1, Int i2 -> Int (if i1 = i2 then 1 else 0)
            | "<", Int i1, Int i2 -> Int (if i1 < i2 then 1 else 0)
            | ">", Int i1, Int i2 -> Int (if i1 > i2 then 1 else 0)
            | _,        _,      _ -> failwith "Unexpected primitive."
        end
  | Let (s, e1, e2) ->
      let let_value = eval e1 env p_stack in
        let env_upd = (s, let_value) :: env in
          eval e2 env_upd p_stack
  | Fun (f_param, f_body, f_perms) -> Closure (f_param, f_body, env, f_perms)
  | Call (f_name, param) -> 
      let f_closure = eval f_name env p_stack in
      begin
        match f_closure with
          | Closure (f_param, f_body, f_dec_env, f_perms) ->
              let p_stack_upd = f_perms :: p_stack in
                let f_param_val = eval param env p_stack_upd in
                  let env_upd = (f_param, f_param_val) :: f_dec_env in
                    eval f_body env_upd p_stack_upd
          | _ -> failwith "Function unknown"
      end
  | Read s ->
      if stackInspection (SS.singleton Pread) p_stack then Int 1
      else failwith "READ denied: lack of permissions"
  | Write s ->
      if stackInspection (SS.singleton Pwrite) p_stack then Int 2
      else failwith "WRITE denied: lack of permissions"
  | Open s ->
      if stackInspection (SS.add Pread (SS.singleton Pwrite)) p_stack then Int 3
      else failwith "OPEN denied: lack of permissions"  
;;

(*
Simple test generator for two nested functions. {permissions} is a list of two elements, where:
- The 1st element is a set of permissions for the EXTERNAL function;
- The 2nd element is a set of permissions for the INTERNAL function;

Corresponding Ocaml code is:

let f = fun x ->
  let g = fun y -> write() in
    g 0
  in f 0
*)
let test_two_nested_functions (permissions : SS.t list) = 
  eval(
    Let(
      "f",
      Fun(
        "x",
        Let(
          "g",
          Fun(
            "y",
            Write("prova"),
            List.nth permissions 1
          ),
          Call(
            Var "g",
            EInt(0)
          )
        ),
        List.hd permissions
      ),
      Call(
        Var "f", EInt(0)
      )
    )
  ) [] [];;

(* Tests *)
(* Using one permission for each function *)
test_two_nested_functions [SS.singleton Pread; SS.singleton Pread];;   (* Result: Fail (no one has Pwrite) *)
test_two_nested_functions [SS.singleton Pwrite; SS.singleton Pread];;  (* Result: Fail (internal misses Pwrite) *)
test_two_nested_functions [SS.singleton Pread; SS.singleton Pwrite];;  (* Result: Fail (external misses Pwrite) *)
test_two_nested_functions [SS.singleton Pwrite; SS.singleton Pwrite];; (* Result: Success *)

(* Using multiple permissions *)
test_two_nested_functions [SS.add Pread (SS.singleton Pwrite); SS.add Pread (SS.singleton Pwrite)];;  (* Result: Success *)
test_two_nested_functions [SS.singleton Pread; SS.add Pread (SS.singleton Pwrite)];;                  (* Result: Fail (external misses Pwrite) *)
