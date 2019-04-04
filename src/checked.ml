open Core_kernel
open Types.Checked

type ('a, 's, 'field) t = ('a, 's, 'field) Types.Checked.t

module T0 = struct
  type nonrec ('a, 's, 'field) t = ('a, 's, 'field) t

  let return x = Pure x

  let rec map : type s a b field.
      (a, s, field) t -> f:(a -> b) -> (b, s, field) t =
   fun t ~f ->
    match t with
    | Pure x -> Pure (f x)
    | Direct (d, k) -> Direct (d, fun b -> map (k b) ~f)
    | Reduced (t, d, res, k) -> Reduced (t, d, res, fun b -> map (k b) ~f)
    | With_label (s, t, k) -> With_label (s, t, fun b -> map (k b) ~f)
    | As_prover (x, k) -> As_prover (x, map k ~f)
    | Add_constraint (c, t1) -> Add_constraint (c, map t1 ~f)
    | With_state (p, and_then, t_sub, k) ->
        With_state (p, and_then, t_sub, fun b -> map (k b) ~f)
    | With_handler (h, t, k) -> With_handler (h, t, fun b -> map (k b) ~f)
    | Clear_handler (t, k) -> Clear_handler (t, fun b -> map (k b) ~f)
    | Exists (typ, c, k) -> Exists (typ, c, fun v -> map (k v) ~f)
    | Next_auxiliary k -> Next_auxiliary (fun x -> map (k x) ~f)

  let map = `Custom map

  let rec bind : type s a b field.
      (a, s, field) t -> f:(a -> (b, s, field) t) -> (b, s, field) t =
   fun t ~f ->
    match t with
    | Pure x -> f x
    | Direct (d, k) -> Direct (d, fun b -> bind (k b) ~f)
    | Reduced (t, d, res, k) -> Reduced (t, d, res, fun b -> bind (k b) ~f)
    | With_label (s, t, k) -> With_label (s, t, fun b -> bind (k b) ~f)
    | As_prover (x, k) -> As_prover (x, bind k ~f)
    (* Someday: This case is probably a performance bug *)
    | Add_constraint (c, t1) -> Add_constraint (c, bind t1 ~f)
    | With_state (p, and_then, t_sub, k) ->
        With_state (p, and_then, t_sub, fun b -> bind (k b) ~f)
    | With_handler (h, t, k) -> With_handler (h, t, fun b -> bind (k b) ~f)
    | Clear_handler (t, k) -> Clear_handler (t, fun b -> bind (k b) ~f)
    | Exists (typ, c, k) -> Exists (typ, c, fun v -> bind (k v) ~f)
    | Next_auxiliary k -> Next_auxiliary (fun x -> bind (k x) ~f)
end

module Types = struct
  module Checked = struct
    type nonrec ('a, 's, 'f) t = ('a, 's, 'f) t

    type ('a, 's, 'f, 'arg) thunk = ('a, 's, 'f) t
  end

  module As_prover = struct
    type ('a, 'f, 's) t = ('a, 'f, 's) As_prover0.t
  end

  module Provider = Types.Provider

  module Typ = struct
    type ('var, 'value, 'f) t =
      ('var, 'value, 'f, (unit, unit, 'f) Checked.t) Types.Typ.t

    module T = Types.Typ.T
    include T
  end

  module Data_spec = struct
    type ('r_var, 'r_value, 'k_var, 'k_value, 'f) t =
      ( 'r_var
      , 'r_value
      , 'k_var
      , 'k_value
      , 'f
      , (unit, unit, 'f) Checked.t )
      Types.Data_spec.t

    module T = Types.Data_spec.T
    include T
  end
end

module Basic :
  Checked_intf.Basic with type 'f field = 'f with module Types = Types = struct
  module Types = Types

  type ('a, 's, 'f) t = ('a, 's, 'f) Types.Checked.t

  type 'f field = 'f

  include Monad_let.Make3 (T0)

  let add_constraint c = Add_constraint (c, return ())

  let as_prover x = As_prover (x, return ())

  let with_label lbl x = With_label (lbl, x, return)

  let with_state p and_then sub = With_state (p, and_then, sub, return)

  let with_handler h x = With_handler (h, x, return)

  let clear_handler x = Clear_handler (x, return)

  let exists typ p = Exists (typ, p, return)

  let next_auxiliary = Next_auxiliary return
end

module Make
    (Basic : Checked_intf.Basic') :
  Checked_intf.S
  with type 'f field = 'f Basic.field
  with module Types = Basic.Types = struct
  include Basic

  type ('a, 's, 'f) t = ('a, 's, 'f) Types.Checked.t

  let request_witness (typ : ('var, 'value, 'f field) Types.Typ.t)
      (r : ('value Request.t, 'f field, 's) As_prover0.t) =
    let%map h = exists typ (Request r) in
    Handle.var h

  let request ?such_that typ r =
    match such_that with
    | None -> request_witness typ (As_prover0.return r)
    | Some such_that ->
        let open Let_syntax in
        let%bind x = request_witness typ (As_prover0.return r) in
        let%map () = such_that x in
        x

  let exists_handle ?request ?compute typ =
    let provider =
      let request =
        Option.value request ~default:(As_prover0.return Request.Fail)
      in
      match compute with
      | None -> Provider.Request request
      | Some c -> Provider.Both (request, c)
    in
    exists typ provider

  let exists ?request ?compute typ =
    let%map h = exists_handle ?request ?compute typ in
    Handle.var h

  type response = Request.response

  let unhandled = Request.unhandled

  type request = Request.request =
    | With :
        { request: 'a Request.t
        ; respond: 'a Request.Response.t -> response }
        -> request

  let handle t k = with_handler (Request.Handler.create_single k) t

  let do_nothing _ = As_prover0.return ()

  let with_state ?(and_then = do_nothing) f sub = with_state f and_then sub

  let assert_ ?label c =
    add_constraint (List.map c ~f:(fun c -> Constraint.override_label c label))

  let assert_r1cs ?label a b c = assert_ (Constraint.r1cs ?label a b c)

  let assert_square ?label a c = assert_ (Constraint.square ?label a c)

  let assert_all =
    let map_concat_rev xss ~f =
      let rec go acc xs xss =
        match (xs, xss) with
        | [], [] -> acc
        | [], xs :: xss -> go acc xs xss
        | x :: xs, _ -> go (f x :: acc) xs xss
      in
      go [] [] xss
    in
    fun ?label cs ->
      add_constraint
        (map_concat_rev ~f:(fun c -> Constraint.override_label c label) cs)

  let assert_equal ?label x y = assert_ (Constraint.equal ?label x y)
end


module T = struct
  include (
    Make
      (Basic) :
      Checked_intf.S' with type 'f field = 'f with module Types := Types )
end

include T

let rec constraint_count_aux : type a s.
    log:(?start:_ -> _) -> int -> (a, s, _) Types.Checked.t -> int * a =
 fun ~log count t0 ->
  match t0 with
  | Pure x -> (count, x)
  | Direct (d, k) ->
      let state = Run_state.dummy_state () in
      (* We can't inspect a direct computation, so we skip it. *)
      (* TODO: Create a constraint system from the computation and extract
               the number of constraints from there. *)
      let _, x = d state in
      constraint_count_aux ~log count (k x)
  | Reduced (t, _, _, k) ->
      let count, y = constraint_count_aux ~log count t in
      constraint_count_aux ~log count (k y)
  | As_prover (_x, k) -> constraint_count_aux ~log count k
  | Add_constraint (_c, t) -> constraint_count_aux ~log (count + 1) t
  | Next_auxiliary k -> constraint_count_aux ~log count (k 1)
  | With_label (s, t, k) ->
      log ~start:true s count ;
      let count', y = constraint_count_aux ~log count t in
      log s count' ;
      constraint_count_aux ~log count' (k y)
  | With_state (_p, _and_then, t_sub, k) ->
      let count', y = constraint_count_aux ~log count t_sub in
      constraint_count_aux ~log count' (k y)
  | With_handler (_h, t, k) ->
      let count, x = constraint_count_aux ~log count t in
      constraint_count_aux ~log count (k x)
  | Clear_handler (t, k) ->
      let count, x = constraint_count_aux ~log count t in
      constraint_count_aux ~log count (k x)
  | Exists ({alloc; check; _}, _c, k) ->
      let alloc_var () = Cvar.Var 1 in
      let var = Typ_monads.Alloc.run alloc alloc_var in
      (* TODO: Push a label onto the stack here *)
      let count, () = constraint_count_aux ~log count (check var) in
      constraint_count_aux ~log count (k {Handle.var; value= None})

let constraint_count ?(log = fun ?start:_ _ _ -> ())
    (t : (_, _, _) Types.Checked.t) : int =
  fst (constraint_count_aux ~log 0 t)
