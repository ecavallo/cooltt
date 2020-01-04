module CS = ConcreteSyntax
module S = Syntax
module D = Domain
module EM = ElabMonad
module Env = ElabEnv
module Err = ElabError

open Monad.Notation (EM)

let rec int_to_term = 
  function
  | 0 -> S.Zero
  | n -> S.Suc (int_to_term (n - 1))

let read_sem_env =
  let+ env = EM.read in
  Env.to_sem_env env

let eval_tp tp =
  let* st = EM.get in
  let* sem_env = read_sem_env in
  match Nbe.eval_tp st sem_env tp with
  | v -> EM.ret v
  | exception exn -> EM.throw exn

let eval_tm tp =
  let* st = EM.get in
  let* sem_env = read_sem_env in
  match Nbe.eval st sem_env tp with
  | v -> EM.ret v
  | exception exn -> EM.throw exn

let inst_tp_clo clo v =
  let* st = EM.get in
  match Nbe.do_tp_clo st clo v with
  | v -> EM.ret v
  | exception exn -> EM.throw exn

let equate tp l r =
  let* st = EM.get in
  let* env = EM.read in
  match
    Nbe.equal_nf st (Env.size env)
      (D.Nf {tp; term = l})
      (D.Nf {tp; term = r})
  with
  | true -> EM.ret ()
  | false -> EM.throw @@ Err.ElabError (Err.ExpectedEqual (tp, l, r))

let equate_tp tp tp' =
  let* st = EM.get in
  let* env = EM.read in
  match Nbe.equal_tp st (Env.size env) tp tp' with
  | true -> EM.ret ()
  | false -> EM.throw @@ Err.ElabError (Err.ExpectedEqualTypes (tp, tp'))

let lookup_var id =
  let* res = EM.resolve id in
  match res with
  | `Local ix ->
    let* tp = EM.get_local_tp ix in
    EM.ret (S.Var ix, tp)
  | `Global sym -> 
    let* D.Nf {tp; _} = EM.get_global sym in 
    EM.ret (S.Global sym, tp)
  | `Unbound -> 
    EM.throw @@ Err.ElabError (Err.UnboundVariable id)

let dest_pi = 
  function
  | D.Pi (base, fam) -> EM.ret (base, fam)
  | tp -> EM.throw @@ Err.ElabError (Err.ExpectedConnective (`Pi, tp))


module Refine : sig 
  type chk_tac = D.tp -> S.t EM.m

  val unleash_hole : CS.ident option -> chk_tac

  val pi_intro : CS.ident option -> chk_tac -> chk_tac
  val sg_intro : chk_tac -> chk_tac -> chk_tac
  val id_intro : chk_tac
  val literal : int -> chk_tac

  val tac_multilam : CS.ident list -> chk_tac -> chk_tac
end =
struct
  type chk_tac = D.tp -> S.t EM.m

  let unleash_hole name tp = 
    let rec go_tp : Env.cell list -> S.tp m =
      function
      | [] ->
        EM.quote_tp tp
      | (D.Nf cell, name) :: cells -> 
        let+ base = EM.quote_tp cell.tp
        and+ fam = EM.push_var name cell.tp @@ go_tp cells in
        S.Pi (base, fam)
    in

    let rec go_tm ne : Env.cell list -> D.ne =
      function 
      | [] -> ne
      | (nf, _) :: cells ->
        D.Ap (go_tm ne cells, nf)
    in

    let* ne = 
      let* env = EM.read in
      EM.globally @@ 
      let+ sym = 
        let* tp = go_tp @@ Env.locals env in
        let* vtp = eval_tp tp in
        EM.add_global name vtp None 
      in
      go_tm (D.Global sym) @@ Env.locals env 
    in

    EM.quote_ne ne


  let pi_intro name tac_body = 
    function
    | D.Pi (base, fam) ->
      EM.push_var name base @@ 
      let* var = EM.get_local 0 in
      let* fib = inst_tp_clo fam var in
      let+ t = tac_body fib in
      S.Lam t
    | tp ->
      EM.throw @@ Err.ElabError (Err.ExpectedConnective (`Pi, tp))

  let sg_intro tac_fst tac_snd = 
    function
    | D.Sg (base, fam) ->
      let* tfst = tac_fst base in
      let* vfst = eval_tm tfst in
      let* fib = inst_tp_clo fam vfst in
      let+ tsnd = tac_snd fib in
      S.Pair (tfst, tsnd)
    | tp ->
      EM.throw @@ Err.ElabError (Err.ExpectedConnective (`Sg, tp))

  let id_intro =
    function
    | D.Id (tp, l, r) ->
      let+ () = equate tp l r
      and+ t = EM.quote tp l in
      S.Refl t
    | tp ->
      EM.throw @@ Err.ElabError (Err.ExpectedConnective (`Id, tp))

  let literal n = 
    function
    | D.Nat ->
      EM.ret @@ int_to_term n
    | tp ->
      EM.throw @@ Err.ElabError (Err.ExpectedConnective (`Nat, tp))

  let rec tac_multilam names tac_body =
    match names with
    | [] -> tac_body
    | name :: names -> 
      pi_intro (Some name) @@ 
      tac_multilam names tac_body
end

let rec check_tp : CS.t -> S.tp EM.m = 
  function
  | CS.Pi (cells, body) -> check_pi_tp cells body
  | CS.Sg (cells, body) -> check_sg_tp cells body
  | CS.Nat -> EM.ret S.Nat
  | CS.Id (tp, l, r) ->
    let* tp = check_tp tp in
    let* vtp = eval_tp tp in
    let+ l = check_tm l vtp
    and+ r = check_tm r vtp in
    S.Id (tp, l, r)
  | tp -> EM.throw @@ Err.ElabError (Err.InvalidTypeExpression tp)

and check_tm : CS.t -> D.tp -> S.t EM.m =
  function
  | CS.Hole name ->
    Refine.unleash_hole name
  | CS.Refl _ ->
    Refine.id_intro 
  | CS.Lit n ->
    Refine.literal n
  | CS.Lam (BN bnd) ->
    Refine.tac_multilam bnd.names @@ check_tm bnd.body
  | cs ->
    fun tp ->
      let* tm, tp' = synth_tm cs in
      let+ () = equate_tp tp tp' in
      tm

and synth_tm : CS.t -> (S.t * D.tp) EM.m = 
  function
  | CS.Var id -> lookup_var id
  | CS.Ap (t, ts) ->
    let* t, tp = synth_tm t in
    synth_ap t tp ts
  | cs -> 
    failwith @@ "TODO : " ^ CS.show cs

and synth_ap head head_tp spine =
  match spine with
  | [] -> EM.ret (head, head_tp)
  | CS.Term arg :: spine ->
    let* base, fam = dest_pi head_tp in
    let* arg = check_tm arg base in
    let* varg = eval_tm arg in
    let* fib = inst_tp_clo fam varg in
    synth_ap (S.Ap (head, arg)) fib spine

and check_sg_tp cells body =
  match cells with
  | [] -> check_tp body
  | Cell cell :: cells ->
    let* base = check_tp cell.tp in
    let* vbase = eval_tp base in
    let+ fam = EM.push_var (Some cell.name) vbase @@ check_sg_tp cells body in
    S.Sg (base, fam)

and check_pi_tp cells body =
  match cells with
  | [] -> check_tp body
  | Cell cell :: cells ->
    let* base = check_tp cell.tp in
    let* vbase = eval_tp base in
    let+ fam = EM.push_var (Some cell.name) vbase @@ check_pi_tp cells body in
    S.Pi (base, fam)