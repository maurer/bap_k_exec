open Core_kernel.Std
open Bap.Std

module AS = Addr.Set

type 'a trace_step = {
  state : 'a;
  k     : int;
  term  : bool;
}

let init_step k u = {
  state = u;
  k     = k;
  term  = false;
}

module Dis = Disasm_expert.Basic

type 'a trace_func = addr -> Dis.full_insn -> stmt list -> 'a trace_step -> ('a trace_step * addr list * bool)

let opt_error msg = function
  | None -> Or_error.error_string msg
  | Some v -> Or_error.return v

type term_cond =
  | Invalid_term
  | User_term
  | Early_term
  | K_term
  | Unmapped_term

exception Abort of string

let exec_insn f (mem, opt_insn) (s, _, _) =
  if (s.term) then (s, [], false) else
  let inval_dis_msg = "Invalid disasms terminate. They should not be here." in
  let insn = Option.value_exn ~message:inval_dis_msg opt_insn in
  match Bap_disasm_arm_lifter.insn mem insn with
   | Ok(bil) -> f (Memory.min_addr mem) insn bil s
   | Error(_) -> 
       (* This isn't quite right, since it will report user_term *)
       (* I should find a way to make invalid_term happen instead *)
       ({s with term = true}, [], false)
    
   

let k_exec image ~start ~k ~f ~init:u_init =
  (* By the invariant of find_addr, Memory.view should not error *)
  let get_mem addr = Option.(Table.find_addr (Image.sections image) addr >>| fst >>| Memory.view ~from:addr >>| ok_exn) in
  let open Or_error in
  get_mem start |> opt_error "Could not find section" >>= fun mem ->
  Dis.create ~backend:"llvm" (Arch.to_string `arm) >>= fun dis ->
  let dis = Dis.store_asm @@ Dis.store_kinds dis in
  let open Sequence.Generator in 
  let init = init_step k u_init in
  Dis.run dis mem ~stop_on:[`May_affect_control_flow] 
    ~return:(fun _ -> return ())
    ~init
    ~invalid:(fun _ _ s -> yield (Invalid_term, s.state))
    ~hit:(fun d _ _ s ->
      if s.k = 0 then yield (K_term, s.state) else
      (* Run the insn sequence *)
      let (s, tgts, fall) = List.fold_right (Dis.insns d) ~f:(exec_insn f) ~init:(s, [], false) in
      (* Decrement the step count *)
      let s = {s with k = s.k - 1} in
      if s.term then yield (User_term, s.state) else
      (* Hit all jump targets *)
      List.fold_left tgts ~f:(fun m tgt -> m >>= fun _ ->
        match get_mem tgt with
          | Some mem -> Dis.jump d mem s
          | None     -> yield (Unmapped_term, s.state))
        ~init:(return ()) >>= fun _ ->
      (* If we're going to fall through, do so *)
      if fall
        then Dis.step d s
        else return ()
    )
    ~stopped:(fun _ s -> yield @@ (Early_term, s.state)) |> run |> Or_error.return
