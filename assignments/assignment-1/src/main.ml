(* Elementary types *)
type expr =
  (* == Values == *)
  | EChar of char
  | EInt of int
  | EBool of bool
  | Var of string
  | ETransition of expr * expr * expr
  (* needed only to define singleton lists *)
  | ESingleList of expr
  (* kinda: EList:= expr * EList | expr * expr (last element of the list) *)
  | EList of expr * expr
  (* == Commands == *)
  | Let of string * expr
  | LetIn of string * expr * expr
  | Prim of string * expr * expr
  | If of expr * expr * expr
  | Fun of string * expr
  | Call of expr * expr
  | FunR of string * string * expr
  | Letrec of string * string * expr * expr
  | CSeq of expr * expr
  (* == Priviliged operations == *)
  | Read of string
  | Write of string
  (* == Security == *)
  | Policy of expr * expr * expr
  | Phi of expr * expr

(* Environment definition: association list, i.e., a list of pair (identifier, data) *)
type 'v env = (string * 'v) list

(* Runtime value definition (boolean are encoded as integers) *)
type value =
  (* == Values == *)
  | Char of char
  | Int of int
  | Transition of int * char * int
  | VList of value list
  (* == Closures == *)
  | Closure of string * expr
  | RecClosure of string * string * expr
  (* == Security == *)
  | Dfa of {
      start : int;
      transitions : (int * char * int) list;
      accepting : int list;
    }

(* Function to return data bounded to {x} in the environment *)
let rec lookup env x =
  match env with
  | [] -> failwith (x ^ " not found")
  | (y, v) :: r -> if x = y then v else lookup r x

(* === Decomposition functions === *)
(* 
    needed to pass from values in AST to real OCaml's values
    - this because when we use the DFA we use OCaml's values!
      - we wanted to reuse the dfa's code
      - also in the AST there should not appear Ocaml's values
*)

(* Decompose Char to char *)
let dec_Char v =
  match v with
  | Char c -> c
  | _ -> failwith "Expected input with type Char."

(* Decompose Int to int *)
let dec_Int v =
  match v with
  | Int i -> i
  | _ -> failwith "Expected input with type Int."

(* Decompose Transition to (int * char * int) *)
let dec_Transition v =
  match v with
  | Transition (i1, c, i2) -> (i1, c, i2)
  | _ -> failwith "Expected input with type Transition."

(* Converts from Ints' list to int list *)
let dec_Int_list l =
  match l with
  | VList l ->
      let rec cast_internal ll =
        match ll with
        | [] -> []
        | h :: t -> dec_Int h :: cast_internal t
      in
      cast_internal l
  | _ -> failwith "Expected input with type Int list."

(* Decompose Transition list to (int * char * int) list *)
let dec_Transition_list v =
  match v with
  | VList l ->
      let rec cast_internal ll =
        match ll with
        | [] -> []
        | h :: t -> dec_Transition h :: cast_internal t
      in
      cast_internal l
  | _ -> failwith "Expected input with type Transition list."

(* === DFA implementation === *)
(* Check if s is accepted by a DFA *)
let dfa_accepts s dfa =
  match dfa with
  | Dfa dfa ->
      (* this substitute the explode *)
      let symbols = List.init (String.length s) (String.get s) in
      let transition state symbol =
        let rec find_state l =
          match l with
          | (s1, sym, s2) :: tl ->
              if s1 = state && symbol = sym then s2 else find_state tl
          | _ -> failwith "State transition not found."
        in
        find_state dfa.transitions
      in
      let final_state =
        let rec h symbol_list =
          match symbol_list with
          | [ hd ] -> transition dfa.start hd
          | hd :: tl -> transition (h tl) hd
          | _ -> failwith "String that DFA must verify is not valid."
        in
        h (List.rev symbols)
      in
      if List.mem final_state dfa.accepting then true else false
  | _ -> failwith "Invalid DFA."

(* === Interpreter === *)
let rec eval (e : expr) (env : (string * value) list) (eta : string)
    (dfa_list : value list) =
  match e with
  | EChar c -> (Char c, env, eta, dfa_list)
  | EInt n -> (Int n, env, eta, dfa_list)
  | EBool n ->
      let n_int = if n then Int 1 else Int 0 in
      (n_int, env, eta, dfa_list)
  | Var x -> (lookup env x, env, eta, dfa_list)
  | ETransition (from_state, label, to_state) ->
      let from_state, env, eta, dfa_list = eval from_state env eta dfa_list in
      let label, env, eta, dfa_list = eval label env eta dfa_list in
      let to_state, env, eta, dfa_list = eval to_state env eta dfa_list in
      ( Transition (
            dec_Int from_state,
            dec_Char label,
            dec_Int to_state
          ), env, eta, dfa_list )
  | ESingleList (e1) -> let e1_value, env, eta, dfa_list = eval e1 env eta dfa_list in
      (VList [e1_value], env, eta, dfa_list)
  | EList (e1, e2) ->
      (* Internal function to create an `OCaml list` from a sequence of `VList` *)
      let rec evaluate_list e =
        match e with
        | EList (e3, e4) ->
            let eval1, env, eta, dfa_list = eval e3 env eta dfa_list in
            eval1 :: evaluate_list e4
        | e_last ->
            let eval1, env, eta, dfa_list = eval e_last env eta dfa_list in
            [ eval1 ]
      in
      (VList (evaluate_list e), env, eta, dfa_list)
  | Let (s, e1) ->
      let let_value, env, eta, dfa_list = eval e1 env eta dfa_list in
      let env_upd = (s, let_value) :: env in
      (let_value, env_upd, eta, dfa_list)
  | LetIn (s, e1, e2) ->
      let let_value, env, eta, dfa_list = eval e1 env eta dfa_list in
      let env_upd = (s, let_value) :: env in
    (* We do not keep env_upd after evaluating in_value *)
      let in_value, _, eta, dfa_list = eval e2 env_upd eta dfa_list in
      (in_value, env, eta, dfa_list)
  | Prim (op, e1, e2) -> (
      let v1, env, eta, dfa_list = eval e1 env eta dfa_list in
      let v2, env, eta, dfa_list = eval e2 env eta dfa_list in
      match (op, v1, v2) with
      | "*", Int i1, Int i2 -> (Int (i1 * i2), env, eta, dfa_list)
      | "+", Int i1, Int i2 -> (Int (i1 + i2), env, eta, dfa_list)
      | "-", Int i1, Int i2 -> (Int (i1 - i2), env, eta, dfa_list)
      | "=", Int i1, Int i2 -> (Int (if i1 = i2 then 1 else 0), env, eta, dfa_list)
      | "<", Int i1, Int i2 -> (Int (if i1 < i2 then 1 else 0), env, eta, dfa_list)
      | ">", Int i1, Int i2 -> (Int (if i1 > i2 then 1 else 0), env, eta, dfa_list)
      | _, _, _ -> failwith "Unexpected primitive.")
  | If (e1, e2, e3) -> (
      let v1, env, eta, dfa_list = eval e1 env eta dfa_list in
      match v1 with
      | Int 1 -> eval e2 env eta dfa_list
      | Int 0 -> eval e3 env eta dfa_list
      | _ -> failwith "Unexpected condition.")
  | Fun (f_param, f_body) -> (Closure (f_param, f_body), env, eta, dfa_list)
  | Call (f_name, param) -> 
      let f_closure, env, eta, dfa_list = eval f_name env eta dfa_list in
      begin
        match f_closure with
        | Closure (f_param, f_body) ->
            let f_param_val, env, eta, dfa_list = eval param env eta dfa_list in
            let env_upd = (f_param, f_param_val) :: env in
            eval f_body env_upd eta dfa_list
        | RecClosure(rec_f_name, f_param, f_body) ->
            let f_param_val, env, eta, dfa_list = eval param env eta dfa_list in
            let env_upd = (rec_f_name, f_closure)::(f_param, f_param_val)::env in
            eval f_body env_upd eta dfa_list
        | _ -> failwith "Function unknown"
      end
  | FunR (rec_f_name, f_param, f_body) -> (RecClosure(rec_f_name, f_param, f_body), env, eta, dfa_list)
  | Letrec (rec_f_name, f_param, f_body, let_body) ->
      let rval, env, eta, dfa_list = eval (FunR(rec_f_name, f_param, f_body)) env eta dfa_list in
      let env_upd = (rec_f_name, rval)::env in
      eval let_body env_upd eta dfa_list
  | CSeq (e1, e2) ->
      let e1_value, env_upd, eta_upd, dfa_list_upd = eval e1 env eta dfa_list in
      eval e2 env_upd eta_upd dfa_list_upd
  | Read s ->
      let eta_upd = eta ^ "r" in
      if List.for_all (dfa_accepts eta_upd) dfa_list then (Char 'r', env, eta_upd, dfa_list)
      else failwith "READ denied: policy restricted."
  | Write s ->
      let eta_upd = eta ^ "w" in
      if List.for_all (dfa_accepts eta_upd) dfa_list then (Char 'w', env, eta_upd, dfa_list)
      else failwith "WRITE denied: policy restricted."
  | Policy (start, transitions, accepting) ->
      let start, env, eta, dfa_list = eval start env eta dfa_list in
      let transitions, env, eta, dfa_list = eval transitions env eta dfa_list in
      let accepting, env, eta, dfa_list = eval accepting env eta dfa_list in
      ( Dfa {
            start = dec_Int start;
            transitions = dec_Transition_list transitions;
            accepting = dec_Int_list accepting;
          }, env, eta, dfa_list )
  | Phi (dfa_expr, e) ->
      let dfa_value, env, eta, dfa_list = eval dfa_expr env eta dfa_list in
      eval e env eta (dfa_value :: dfa_list)
;;

(* === Policies for tests === *)
(* No Read after Write (Chinese Wall) *)
let noRaW = Policy(
  (* Starting node *)
  EInt(0),
  (* Transitions list *)
  EList( ETransition(EInt(0), EChar('r'), EInt(0)),
          EList( ETransition(EInt(0), EChar('w'), EInt(1)),
                EList( ETransition(EInt(1), EChar('w'), EInt(1)),
                        EList( ETransition(EInt(1), EChar('r'), EInt(2)),
                              EList( ETransition(EInt(2), EChar('r'), EInt(2)),
                                      ETransition(EInt(2), EChar('w'), EInt(2))
                                    )
                            )
                      )
              )
        ),
  (* Accepting nodes *)
  EList( EInt(0), EInt(1) )
);;

(* No Write after Read *)
let noWaR = Policy(
  (* Starting node *)
  EInt(0),
  (* Transitions list *)
  EList( ETransition(EInt(0), EChar('w'), EInt(0)),
          EList( ETransition(EInt(0), EChar('r'), EInt(1)),
                EList( ETransition(EInt(1), EChar('r'), EInt(1)),
                        EList( ETransition(EInt(1), EChar('w'), EInt(2)),
                              EList( ETransition(EInt(2), EChar('w'), EInt(2)),
                                     ETransition(EInt(2), EChar('r'), EInt(2))
                                   )
                            )
                      )
              )
        ),
  (* Accepting nodes *)
  EList( EInt(0), EInt(1) )
);;

(* === Tests === *)
let test_external_internal_phi policy_name policy op1 op2 =
  eval (
    CSeq(
      Let(policy_name, policy),
      CSeq(
        op1,
        Phi(
          Var(policy_name),
          op2
        )
      )
    )
  ) [] "" [];;

test_external_internal_phi "noRaW" noRaW (Read "./test.txt") (Write "./test.txt");; (* Result: Success *)
test_external_internal_phi "noRaW" noRaW (Write "./test.txt") (Read "./test.txt");; (* Result: Fail (Read performed after Write) *)
test_external_internal_phi "noWaR" noWaR (Write "./test.txt") (Read "./test.txt");; (* Result: Success *)
test_external_internal_phi "noWaR" noWaR (Read "./test.txt") (Write "./test.txt");; (* Result: Fail (Write performed after Read) *)

let test_multiple_phi policy_name1 policy1 policy_name2 policy2 op1 op2 =
  eval (
    CSeq(
      Let(policy_name1, policy1),
      CSeq(
        Let(policy_name2, policy2),
        CSeq(
          op1,
          Phi(
            Var(policy_name1),
            Phi(
              Var(policy_name2),
              op2
            )
          )
        )
      )
    )
  ) [] "" [];;

test_multiple_phi "noRaW" noRaW "noWaR" noWaR (Read "./test.txt") (Read "./test.txt");;   (* Result: Success *)
test_multiple_phi "noRaW" noRaW "noWaR" noWaR (Read "./test.txt") (Write "./test.txt");;  (* Result: Fail (Two different privileged operations performed) *)