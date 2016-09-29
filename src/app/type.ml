
open Util

let app_name = "type"

(*
let freader = Future.Reader.open_file file in
let fastq_rdr = Fastq.read freader in
Future.Pipe.iter fastq_rdr ~f:(fun oe ->
  let fastq_item = Or_error.ok_exn oe in
  let seq = fastq_item.Fastq.sequence in
  match Alignment.align ~mub:3 g kmt seq with
  | Error msg -> eprintf "error %s for seq: %s\n" msg seq
  | Ok als    -> List.iter als ~f:(Alignment.alignments_to_weights amap));
  *)

let sort_values_by_likelihood_assoc =
  (* higher values first! *)
  List.sort ~cmp:(fun (v1, a1) (v2, a2) ->
    let r = compare v2 v1 in
    if r = 0 then compare a2 a1 else r)

let sort_values_by_mismatches_assoc =
  (* lower values first! *)
  List.sort ~cmp:(fun (v1, a1) (v2, a2) ->
    let r = compare v1 v2 in
    if r = 0 then compare a2 a1 else r)

let output_values_assoc ?(set_size=true) aindex =
  let max_length = if set_size then 60 else 1000 in
  List.iter ~f:(fun (w, a) ->
    printf "%0.8f\t%s%s\n" w
      (if set_size then sprintf "%d\t" (Alleles.Set.cardinal a) else "")
      (insert_chars ['\t'; '\t'; '\n']
        (Alleles.Set.to_human_readable aindex ~max_length ~complement:`No a)))

let report_mismatches g amap =
  let open Ref_graph in function
  | None ->
      Alleles.Map.values_assoc g.aindex amap
      |> sort_values_by_mismatches_assoc
      |> output_values_assoc g.aindex
  | Some n ->
      Alleles.Map.fold g.aindex amap ~init:[]
        ~f:(fun a v al -> (v, Alleles.Set.singleton g.aindex al) :: a)
      |> sort_values_by_mismatches_assoc
      |> fun l -> List.take l n
      |> output_values_assoc g.aindex

let report_mislist g amap =
  let open Ref_graph in
  Alleles.Map.iter g.aindex amap ~f:(fun l a ->
      let s = List.rev l |> List.map ~f:(sprintf "%.2f") |> String.concat ~sep:"," in
      printf "%s,\t%s\n" a s)

let report_likelihood g amap do_not_bucket =
  let open Ref_graph in function
  | None ->
      (if do_not_bucket then amap else
        (* Round the values so that it is easier to display. *)
        Alleles.Map.map_wa ~f:(fun x -> (ceil (x *. 10.)) /. 10.) amap)
      |> Alleles.Map.values_assoc g.aindex
      |> sort_values_by_likelihood_assoc
      |> output_values_assoc g.aindex
  | Some n ->
      Alleles.Map.fold g.aindex amap ~init:[]
        ~f:(fun a v al -> (v, Alleles.Set.singleton g.aindex al) :: a)
      |> sort_values_by_likelihood_assoc
      |> fun l -> List.take l n
      |> output_values_assoc g.aindex

let type_ verbose alignment_file num_alt_to_add allele_list k skip_disk_cache
  fastq_file not_join_same_seq number_of_reads print_top multi_pos as_stat
  filter do_not_normalize do_not_bucket likelihood_error =
  let open Cache in
  let open Ref_graph in
  let option_based_fname, g =
    Common_options.to_filename_and_graph_args alignment_file num_alt_to_add
      allele_list (not not_join_same_seq)
  in
  let g, idx = Cache.graph_and_two_index ~skip_disk_cache { k ; g } in
  match as_stat with
  | `MisList  ->
      begin
        let init, f = Path_inference.multiple_fold_lst ~verbose ~multi_pos ?filter g idx in
        let amap =
          (* This is backwards .. *)
          Fastq_reader.fold ?number_of_reads fastq_file ~init ~f:(fun amap seq ->
            if verbose then print_endline "--------------------------------";
            match f amap seq with
            | Error e -> if verbose then printf "error\t%s: %s\n" seq e; amap
            | Ok a    -> if verbose then printf "matched\t%s \n" seq; a)
        in
        report_mislist g amap
      end
  | `Mismatches | `Likelihood | `LogLikelihood as as_ ->
      begin
        let er = likelihood_error in
        let init, f = Path_inference.multiple_fold ~verbose ~multi_pos ~as_ ?filter ?er g idx in
        let amap =
          (* This is backwards .. *)
          Fastq_reader.fold ?number_of_reads fastq_file ~init ~f:(fun amap seq ->
            if verbose then print_endline "--------------------------------";
            match f amap seq with
            | Error e -> if verbose then printf "error\t%s: %s\n" seq e; amap
            | Ok a    -> if verbose then printf "matched\t%s \n" seq; a)
        in
        match as_ with
        | `Mismatches     -> report_mismatches g amap print_top
        | `Likelihood     ->
            let amap =
              if do_not_normalize then amap else
                let sum = Alleles.Map.fold_wa ~f:(+.) ~init:0. amap in
                Alleles.Map.map_wa ~f:(fun v -> v /. sum) amap
            in
            report_likelihood g amap do_not_bucket print_top
        | `LogLikelihood  ->
            let emap =
              if do_not_normalize then
                amap
              else
                let sum = Alleles.Map.fold_wa ~init:0. ~f:(fun s v -> v +. s) amap in
                Alleles.Map.map_wa ~f:(fun v -> v /. sum) amap
            in
            report_likelihood g emap do_not_bucket print_top
            (*let mx = Alleles.Map.fold_wa ~init:neg_infinity ~f:max amap in
            let emap =
              if do_not_normalize then
                Alleles.Map.map_wa ~f:(fun v -> exp (v +. mx)) amap
              else
                let emap = Alleles.Map.map_wa ~f:(fun v -> exp (v -. mx)) amap in
                let sum = Alleles.Map.fold_wa ~init:0. ~f:(fun s v -> v +. s) emap in
                Alleles.Map.map_wa ~f:(fun v -> v /. sum) emap
            in
            report_likelihood g emap do_not_bucket print_top *)
      end

let () =
  let open Cmdliner in
  let open Common_options in
  let print_top_flag =
    let docv = "Print only most likely" in
    let doc = "Print only the specified number (positive integer) of alleles" in
    Arg.(value & opt (some int) None & info ~doc ~docv ["print-top"])
  in
  let multi_pos_flag =
    let d = "How to aggregate multiple position matches: " in
    Arg.(value & vflag `Best
      [ `TakeFirst, info ~doc:(d ^ "take the first, as found in Index.") ["pos-take-first"]
      ; `Average,   info ~doc:(d ^ "average over all positions") ["pos-average"]
      ; `Best,      info ~doc:(d ^ "the best over all positions (default).") ["pos-best"]
      ])
  in
  let stat_flag =
    let d = "What statistics to compute over each sequences: " in
    Arg.(value & vflag `LogLikelihood
      [ `LogLikelihood, info ~doc:(d ^ "log likelihood") ["log-likelihood"]
      ; `Likelihood,    info ~doc:(d ^ "likelihood") ["likelihood"]
      ; `Mismatches,    info ~doc:(d ^ "mismatches, that are then added then added together") ["mismatches"]
      ; `MisList,       info ~doc:(d ^ "list of mismatches") ["mis-list"]
      ])
  in
  let filter_flag =
    let docv = "Filter out sequences" in
    let doc  = "Filter, do not include in the likelihood calculation, sequences \
                where the highest number of mismatches is greater than the passed argument." in
    Arg.(value & opt (some int) None & info ~doc ~docv ["filter-matches"])
  in
  let do_not_normalize_flag =
    let docv = "Do not normalize the likelihoods" in
    let doc  = "Do not normalize the per allele likelihoods to report accurate probabilities." in
    Arg.(value & flag & info ~doc ~docv ["do-not-normalize"])
  in
  let do_not_bucket_flag =
    let docv = "Do not bucket the probabilities" in
    let doc  = "When printing the allele probabilities, do not bucket (by 0.1) the final allele sets" in
    Arg.(value & flag & info ~doc ~docv ["do-not-bucket"])
  in
  let likelihood_error_arg =
    let docv = "Override the likelihood error" in
    let doc  = "Specify the error value used in likelihood calculations, defaults to 0.025" in
    Arg.(value & opt (some float) None & info ~doc ~docv ["likelihood-error"])
  in
  let type_ =
    let version = "0.0.0" in
    let doc = "Use HLA string graphs to type fastq samples." in
    let bug =
      sprintf "Browse and report new issues at <https://github.com/hammerlab/%s"
        repo
    in
    let man =
      [ `S "AUTHORS"
      ; `P "Leonid Rozenberg <leonidr@gmail.com>"
      ; `Noblank
      ; `S "BUGS"
      ; `P bug
      ]
    in
    Term.(const type_
            $ verbose_flag
            $ file_arg $ num_alt_arg $ allele_arg $ kmer_size_arg $ no_cache_flag
            $ fastq_file_arg
            $ do_not_join_same_sequence_paths_flag
            $ num_reads_arg
            $ print_top_flag
            $ multi_pos_flag
            $ stat_flag
            $ filter_flag
            $ do_not_normalize_flag
            $ do_not_bucket_flag
            $ likelihood_error_arg
        , info app_name ~version ~doc ~man)
  in
  match Term.eval type_ with
  | `Ok ()           -> exit 0
  | `Error _         -> failwith "cmdliner error"
  | `Version | `Help -> exit 0
