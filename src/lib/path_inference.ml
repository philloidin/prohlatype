(** Path Inference : Given a read (a sequence of characters return a PDF over
    the edges (alleles) in the graph. *)

open Util

let log_likelihood ?(alph_size=4) ?(er=0.01) ~len mismatches =
  let lmp = log (er /. (float (alph_size - 1))) in
  let lcp = log (1. -. er) in
  let c = (float len) -. mismatches in
  c *. lcp +. mismatches *. lmp

let likelihood ?alph_size ?er ~len m =
  exp (log_likelihood ?alph_size ?er ~len m)

let report_mismatches el_to_string state aindex mm =
  printf "reporting %s mismatches\n" state;
  let () =
    Alleles.Map.values_assoc aindex mm
    |> List.sort ~cmp:(fun (i1,_) (i2,_) -> compare i1 i2)
    |> List.iter ~f:(fun (w, a) ->
        printf "%s\t%s\n"
          (el_to_string w)
          (insert_chars ['\t'; '\t'; '\n']
            (Alleles.Set.to_human_readable aindex ~max_length:10000 ~complement:`No a)))
  in
  printf "finished reporting mismatches\n%!"

module type Single_config = sig

  type t  (* How we measure the alignment of a sequence against an allele. *)

  val to_string : t -> string           (* Display *)

  type stop_parameter
  type thread

  val thread_to_seq : thread -> string

  val compute : ?early_stop:stop_parameter -> Ref_graph.t -> thread -> Index.position ->
    ([ `Finished of t Alleles.Map.t | `Stopped of t Alleles.Map.t ], string) result

  val reduce_across_positions : t Alleles.Map.t -> t Alleles.Map.t list -> t Alleles.Map.t

end (* Single_config *)

type sequence_alignment_error =
  | NoPositions
  | AllStopped of int
  | Other of string
  | ToThread of string

module AgainstSequence (C : Single_config) = struct

  let one ?early_stop g idx seq =
    match Index.lookup idx (C.thread_to_seq seq) with
    | Error e -> Error (Other e)
    | Ok []   -> Error NoPositions
    | Ok ps   ->
        let rec loop acc = function
          | []     -> `Fin acc
          | h :: t ->
              match C.compute ?early_stop g seq h with
              | Error e -> `Errored e
              | Ok r -> loop (r :: acc) t
        in
        match loop [] ps with
        | `Errored e -> Error (Other e)
        | `Fin res ->
            let f = function | `Finished f -> `Fst f | `Stopped s -> `Snd s in
            match List.partition_map res ~f with
            | [], []      -> assert false
            | [], als     -> Error (AllStopped (List.length als))
            | r :: rs, _  -> Ok (C.reduce_across_positions r rs)

  type stop_parameter = C.stop_parameter
  type thread = C.thread

end (* AgainstSequence *)

module ThreadIsJustSequence = struct
  type thread = string
  let thread_to_seq s = s
end

module ListMismatches_config = struct

  type t = (int * int) list
  let to_string l =
    String.concat ~sep:"; "
      (List.map l ~f:(fun (p,v) -> sprintf "(%d,%d)" p v))

  type stop_parameter = int * float

  include ThreadIsJustSequence

  let compute = Alignment.compute_mismatches_lst

  (* Lowest mismatch across all alleles. *)
  let to_min =
    Alleles.Map.fold_wa ~init:max_int ~f:(fun mx lst ->
      let s = List.fold_left lst ~init:0 ~f:(fun s (_, v) -> s + v) in
      min mx s)

  let reduce_across_positions s = function
    | [] -> s
    | ts ->
        let b = to_min s in
        List.fold_left ts ~init:(b, s) ~f:(fun (b, s) m ->
          let bm = to_min m in
          if bm < b then
            (bm, m)
          else
            (b, s))
        |> snd

end (* ListMismatches_config *)

module ListMismatches = AgainstSequence (ListMismatches_config)

module SequenceMismatches = AgainstSequence (struct

  type t = int
  let to_string = sprintf "%d"

  type stop_parameter = int * float

  include ThreadIsJustSequence

  let compute = Alignment.compute_mismatches

  (* Lowest mismatch across all alleles. *)
  let to_min = Alleles.Map.fold_wa ~init:max_int ~f:min
  let reduce_across_positions s = function
    | [] -> s
    | ts ->
        let b = to_min s in
        List.fold_left ts ~init:(b, s) ~f:(fun (b, s) m ->
          let bm = to_min m in
          if bm < b then
            (bm, m)
          else
            (b, s))
        |> snd

end)

module PhredLlhdMismatches = AgainstSequence ( struct

  open Alignment

  type t = PhredLikelihood_config.t
  let to_string = PhredLikelihood_config.to_string

  type stop_parameter = int * float
  type thread = string * float array

  let thread_to_seq (s, _) = s

  let compute = Alignment.compute_plhd

  (* There are 2 ways to compute Best in this case:
     1. lowest number of mismatches as in the other mismatch counting algorithms
     2. highest sum of log likelihoods -> highest probability
     we use 2. *)
  let to_max =
    Alleles.Map.fold_wa ~init:neg_infinity
      ~f:(fun a t -> max a t.PhredLikelihood_config.sum_llhd)

  let reduce_across_positions s = function
    | [] -> s
    | ts ->
        let b = to_max s in
        List.fold_left ts ~init:(b, s) ~f:(fun (b, s) m ->
          let bm = to_max m in
          if bm > b then
            (bm, m)
          else
            (b, s))
        |> snd

end) (* PhredLlhdMismatches *)

module type Multiple_config = sig

  type mp     (* map step *)
  type re     (* reduce across alleles *)

  val empty : re

  type stop_parameter
  type thread

  val to_thread : Biocaml_unix.Fastq.item -> (thread, string) result

  val map :
    ?early_stop:stop_parameter ->
    Ref_graph.t -> Index.t ->
    thread ->
    (mp Alleles.Map.t, sequence_alignment_error) result

  val reduce : mp -> re -> re

end (* Multiple_config *)

module Multiple (C : Multiple_config) = struct

  let fold_over_fastq ?number_of_reads fastq_file ?early_stop g idx =
    let amap = Alleles.Map.make g.Ref_graph.aindex C.empty in
    let f (errors, amap) fqi =
      match C.to_thread fqi with
      | Error e     -> ((ToThread e, fqi) :: errors), amap
      | Ok seq  ->
          match C.map ?early_stop g idx seq with
          | Error e -> ((e, fqi) :: errors), amap
          | Ok a    -> Alleles.Map.update2 ~source:a ~dest:amap C.reduce;
                       errors, amap
    in
    Fastq.fold ?number_of_reads ~init:([], amap) ~f fastq_file

  let map_over_fastq ?number_of_reads fastq_file ?early_stop g idx =
    let f fqi =
      match C.to_thread fqi with
      | Error e     -> Error (ToThread e, fqi)
      | Ok seq  ->
          match C.map ?early_stop g idx seq with
          | Error e -> Error (e, fqi)
          | Ok a    -> Ok a
    in
    Fastq.fold ?number_of_reads ~init:[] fastq_file
      ~f:(fun acc fqi -> (f fqi) :: acc)
    |> List.rev

end (* Multiple *)

(** Typing. *)
let sequence_alignment_error_to_string = function
  | NoPositions  -> "No positions found"
  | AllStopped n -> sprintf "Stopped %d positions" n
  | Other m      -> sprintf "Error: %s" m
  | ToThread m   -> sprintf "ToThread: %s" m

module MismatchesList = Multiple (struct
  type mp = (int * int) list
  type re = (int * int) list list
  let empty = []

  type stop_parameter = ListMismatches.stop_parameter
  type thread = ListMismatches.thread

  let to_thread fqi = Ok fqi.Biocaml_unix.Fastq.sequence
  let map = ListMismatches.one
  let reduce v l = v :: l
end)

module Mismatches = Multiple (struct
  type mp = int
  type re = int
  let empty = 0

  type stop_parameter = SequenceMismatches.stop_parameter
  type thread = SequenceMismatches.thread

  let to_thread fqi = Ok fqi.Biocaml_unix.Fastq.sequence
  let map = SequenceMismatches.one
  let reduce = (+)
end)

module Llhd_config = struct
  type mp = float
  type re = float

  type stop_parameter = SequenceMismatches.stop_parameter
  type thread = SequenceMismatches.thread

  let to_thread fqi = Ok fqi.Biocaml_unix.Fastq.sequence
  let map l ?early_stop g idx th =
    SequenceMismatches.one ?early_stop g idx th >>= fun m ->
      Ok (Alleles.Map.map_wa ~f:(fun m -> l ~len:(String.length th) m) m)

end (* Llhd_config *)

module Phred_lhd = Multiple (struct
  type mp = float
  type re = float

  let empty = 0.

  type stop_parameter = PhredLlhdMismatches.stop_parameter
  type thread = PhredLlhdMismatches.thread

  let to_thread fqi =
    let module CE = Core_kernel.Error in
    let module CR = Core_kernel.Std.Result in
    match Fastq.phred_probabilities fqi.Biocaml_unix.Fastq.qualities with
    | CR.Error e -> Error (CE.to_string_hum e)
    | CR.Ok qarr -> Ok (fqi.Biocaml_unix.Fastq.sequence, qarr)

  let map ?early_stop g idx th =
    let open Alignment in
    PhredLlhdMismatches.one ?early_stop g idx th >>= fun amap ->
      Ok (Alleles.Map.map_wa amap ~f:(fun pt -> pt.PhredLikelihood_config.sum_llhd))

  let reduce = (+.)

end) (* Phred_lhd *)

let map ?filter ?(as_=`PhredLikelihood) g idx ?number_of_reads ~fastq_file =
  let early_stop =
    Option.map filter ~f:(fun n -> Ref_graph.number_of_alleles g, float n)
  in
  match as_ with
  | `MismatchesList       ->
      `MismatchesList (MismatchesList.map_over_fastq
          ?number_of_reads fastq_file ?early_stop g idx)
  | `Mismatches           ->
      `Mismatches (Mismatches.map_over_fastq
          ?number_of_reads fastq_file ?early_stop g idx)
  | `Likelihood error     ->
      let module Ml = Multiple (struct
        include Llhd_config
        let empty = 1.
        let map = map (fun ~len m -> likelihood ~er:error ~len (float m))
        let reduce l a = a *. l
      end) in
      `Likelihood (Ml.map_over_fastq
          ?number_of_reads fastq_file ?early_stop g idx)
  | `LogLikelihood error  ->
      let module Ml = Multiple (struct
        include Llhd_config
        let empty = 0.
        let map = map (fun ~len m -> log_likelihood ~er:error ~len (float m))
        let reduce l a = a +. l
      end) in
      `LogLikelihood (Ml.map_over_fastq
          ?number_of_reads fastq_file ?early_stop g idx)
  | `PhredLikelihood ->
      `PhredLikelihood (Phred_lhd.map_over_fastq
          ?number_of_reads fastq_file ?early_stop g idx)

let type_ ?filter ?(as_=`PhredLikelihood) g idx ?number_of_reads ~fastq_file =
  let early_stop =
    Option.map filter ~f:(fun n -> Ref_graph.number_of_alleles g, float n)
  in
  match as_ with
  | `MismatchesList       ->
      `MismatchesList (MismatchesList.fold_over_fastq
          ?number_of_reads fastq_file ?early_stop g idx)
  | `Mismatches           ->
      `Mismatches (Mismatches.fold_over_fastq
          ?number_of_reads fastq_file ?early_stop g idx)
  | `Likelihood error     ->
      let module Ml = Multiple (struct
        include Llhd_config
        let empty = 1.
        let map = map (fun ~len m -> likelihood ~er:error ~len (float m))
        let reduce l a = a *. l
      end) in
      `Likelihood (Ml.fold_over_fastq
          ?number_of_reads fastq_file ?early_stop g idx)
  | `LogLikelihood error  ->
      let module Ml = Multiple (struct
        include Llhd_config
        let empty = 0.
        let map = map (fun ~len m -> log_likelihood ~er:error ~len (float m))
        let reduce l a = a +. l
      end) in
      `LogLikelihood (Ml.fold_over_fastq
          ?number_of_reads fastq_file ?early_stop g idx)
  | `PhredLikelihood ->
      `PhredLikelihood (Phred_lhd.fold_over_fastq
          ?number_of_reads fastq_file ?early_stop g idx)
