module S = Syntax
module D = Domain
module EM = ElabBasics

open CoolBasis
open Monad.Notation (EM)

module Tp : sig
  type tac

  val make : S.tp EM.m -> tac
  val make_virtual : S.tp EM.m -> tac

  val run : tac -> S.tp EM.m
  val run_virtual : tac -> S.tp EM.m
  val map : (S.tp EM.m -> S.tp EM.m) -> tac -> tac
end
=
struct
  type tac =
    | Virtual of S.tp EM.m
    | General of S.tp EM.m

  let make tac = General tac
  let make_virtual tac = Virtual tac

  let run =
    function
    | General tac -> tac
    | Virtual _ ->
      EM.elab_err @@ ElabError.VirtualType

  let run_virtual =
    function
    | General tac
    | Virtual tac -> tac

  let map f =
    function
    | General tac -> General (f tac)
    | Virtual tac -> Virtual (f tac)
end

module Var =
struct
  type tac = {tp : D.tp; con : D.con}

  let prf phi = {tp = D.TpPrf phi; con = D.Prf}
  let con {tp; con} = con

  let syn {tp; con} =
    let+ tm = EM.lift_qu @@ Nbe.quote_con tp con in
    tm, tp
end

type var = Var.tac
type tp_tac = Tp.tac

type chk_tac = D.tp -> S.t EM.m
type bchk_tac = D.tp * D.cof * D.tm_clo -> S.t EM.m
type syn_tac = (S.t * D.tp) EM.m

let abstract : D.tp -> string option -> (var -> 'a EM.m) -> 'a EM.m =
  fun tp name kont ->
  EM.abstract name tp @@ fun (con : D.con) ->
  kont @@ {tp; con}

let let_ tp con name (kont : var -> 'a EM.m) =
  EM.define name tp con @@ fun var ->
  kont @@ {tp; con}


let bchk_to_chk : bchk_tac -> chk_tac =
  fun btac tp ->
  let triv = D.const_tm_clo D.Abort in
  btac (tp, Cof.bot, triv)


let chk_to_bchk : chk_tac -> bchk_tac =
  fun tac (tp, phi, pclo) ->
  let* tm = tac tp in
  let* con = EM.lift_ev @@ Nbe.eval tm in
  let* () =
    EM.push_var None (D.TpPrf phi) @@
    EM.equate tp con @<< EM.lift_cmp @@ Nbe.inst_tm_clo pclo [D.Prf]
  in
  EM.ret tm

let syn_to_chk (tac : syn_tac) : chk_tac =
  fun tp ->
  let* tm, tp' = tac in
  let+ () = EM.equate_tp tp tp' in
  tm

let chk_to_syn (tac_tm : chk_tac) (tac_tp : tp_tac) : syn_tac =
  let* tp = Tp.run tac_tp in
  let* vtp = EM.lift_ev @@ Nbe.eval_tp tp in
  let+ tm = tac_tm vtp in
  tm, vtp

