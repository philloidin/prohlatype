(* Common arguments shared between programs. *)

open Util
open Cmdliner

let repo = "prohlatype"

(*** Basic command line parsers and printers. ***)
let positive_int_parser w =
  fun s ->
    try
      let d = Scanf.sscanf s "%d" (fun x -> x) in
      if d <= 0 then
        Error (`Msg (s ^ " is not a positive integer"))
      else
        Ok (w d)
    with Scanf.Scan_failure msg ->
      Error (`Msg msg)

let int_fprinter frmt =
  Format.fprintf frmt "%d"

let positive_int =
  Arg.conv ~docv:"POSITIVE INTEGER"
    ((positive_int_parser (fun n -> n)), int_fprinter)

let non_negative_int_parser =
  fun s ->
    try
      let d = Scanf.sscanf s "%d" (fun x -> x) in
      if d < 0 then
        Error (`Msg (s ^ " is negative"))
      else
        Ok d
    with Scanf.Scan_failure msg ->
      Error (`Msg msg)

let non_negative_int =
  Arg.conv ~docv:"NON-NEGATIVE INTEGER"
    (non_negative_int_parser, int_fprinter)

(*** Graph source arguments. ***)
let file_arg =
  let docv = "FILE" in
  let doc  = "File to lookup IMGT allele alignments. The alleles found in this\
              file will initially define the set of alleles to be used. Use an\
              allele selector to modify this set." in
  Arg.(value & opt (some file) None & info ~doc ~docv ["f"; "file"])

let merge_arg =
  let parser path =
    let s = Filename.basename path in
    let n = path ^ "_nuc.txt" in
    let g = path ^ "_gen.txt" in
    if not (List.mem ~set:Merge_mas.supported_genes s) then
      `Error ("gene not supported: " ^ s)
    else if not (Sys.file_exists n) then
      `Error ("Nuclear alignment file doesn't exist: " ^ n)
    else if not (Sys.file_exists g) then
      `Error ("Genetic alignment file doesn't exist: " ^ n)
    else
      `Ok path  (* Return path, and do appending later, the prefix is more useful. *)
  in
  let convrtr = parser, (fun frmt -> Format.fprintf frmt "%s") in
  let docv = sprintf "[%s]" (String.concat ~sep:"|" Merge_mas.supported_genes) in
  let doc  =
    sprintf "Construct a merged (gDNA and cDNA) graph of the specified \
             prefix path. Currently only supports %s genes. The argument must \
             be a path to files with $(docv)_nuc.txt and $(docv)_gen.txt. \
             Overrides the file arguments. The set of alleles is defined by the
             ones in the nuc file."
      (String.concat ~sep:", " Merge_mas.supported_genes)
  in
  Arg.(value & opt (some convrtr) None & info ~doc ~docv ["m"; "merge"])

(*** Allele selector arguments. ***)
let regex_command_line_args = ["allele-regex"]
let allele_command_line_args = ["a"; "allele"]
let without_command_line_args = ["without-allele"]
let num_command_line_args = ["n"; "num-alt"]

let args_to_string lst =
  List.map lst ~f:(fun s -> (if String.length s = 1 then "-" else "--") ^ s)
  |> String.concat ~sep:", "

let regex_arg =
  let docv = "REGEX" in
  let doc  = "Specify alleles to add to the graph via a regex. This option is \
              similar to allele, but lets the user specify a wider range \
              (specifically those alleles matching a POSIX regex) of alleles \
              to include. The '*' used in HLA allele names must be properly \
              escaped from the command line: ex. -ar \"A*02:03\". This \
              \"allele selector\" has the highest precedence, and is applied \
              to all of the alleles from the working set"
  in
  let open Arg in
  let parser_ = parser_of_kind_of_string ~kind:docv
    (fun s -> Some (Alleles.Selection.Regex s))
  in
  value & opt_all (conv ~docv (parser_, Alleles.Selection.pp)) []
        & info ~doc ~docv regex_command_line_args

let allele_arg =
  let docv = "STRING" in
  let doc  =
    sprintf "Specify specfic alleles to add to the graph. \
             This \"allele selector\" is applied after regex (%s) \
             but before the without (%s). \
             Use this option to construct a graph with specific alleles (ex. \
             A*01:02). One can repeat this argument to specify multiple \
             alleles."
      (args_to_string regex_command_line_args)
      (args_to_string without_command_line_args)
  in
  let open Arg in
  let parser_ =
    parser_of_kind_of_string ~kind:docv
      (fun s -> Some (Alleles.Selection.Specific s))
  in
  value & opt_all (conv ~docv (parser_, Alleles.Selection.pp)) []
        & info ~doc ~docv allele_command_line_args

let without_arg =
  let docv = "STRING" in
  let doc  =
    sprintf "Alleles to remove from the working set. \
             This \"allele selector\" is applied before the execlude (%s)
             selector but after specific (%s) one.
             Use this option to construct a graph without alleles (ex. \
             A*01:02). One can repeat this argument to specify multiple \
             alleles to exclude."
      (args_to_string allele_command_line_args)
      (args_to_string num_command_line_args)
  in
  let open Arg in
  let parser_ =
    parser_of_kind_of_string ~kind:docv
      (fun s -> Some (Alleles.Selection.Without s))
  in
  value & opt_all (conv ~docv (parser_, Alleles.Selection.pp)) []
        & info ~doc ~docv without_command_line_args

let num_alt_arg =
  let docv = "POSITIVE INTEGER" in
  let doc  =
    sprintf "Number of alternate alleles to add to the graph. \
             If not specified, all of the alternate alleles in the alignment \
             file are added. This \"allele selector\" is applied last to the
             working set of alleles derived from the alignment file \
             (ex. A_gen, DRB_nuc) or merge request (ex. B) after the without
             argument (%s)"
             (args_to_string without_command_line_args)

  in
  let open Arg in
  let parser_ = (positive_int_parser (fun d -> Alleles.Selection.Number d)) in
  let nconv = conv ~docv (parser_, Alleles.Selection.pp) in
  (value & opt (some nconv) None & info ~doc ~docv num_command_line_args)

(*** Other args. ***)
let remove_reference_flag =
  let doc  = "Remove the reference allele from the graph. The reference \
              allele is the one that is listed first in the alignments file. \
              Graphs are currently constructed based upon their \"diff\" to \
              the reference as represented in the alignments file. Therefore, \
              the original reference sequence must be a part of the graph \
              during construction. Specifying this flag will remove it from \
              the graph after the other alleles are added."
  in
  Arg.(value & flag & info ~doc ["no-reference"])

let impute_flag =
  let doc  = "Fill in the missing segments of alleles with an iterative \
              algorithm that picks the closest allele with full length."
  in
  Arg.(value & flag & info ~doc ["impute"])

let no_cache_flag =
  let doc =
    sprintf "Do not use a disk cache (in %s sub directory of the current \
             directory) to search for previously (and then save) constructed \
             graphs."
      Cache.dir
  in
  Arg.(value & flag & info ~doc ["no-cache"])

let do_not_join_same_sequence_paths_flag =
  let doc = "Do not join same sequence paths; remove overlapping nodes at the \
             same position, in the string graph."
  in
  Arg.(value & flag & info ~doc ["do-not-join-same-sequence-paths"])

let to_input ?alignment_file ?merge_file ~distance ~impute () =
  match alignment_file, merge_file with
  | _,          (Some prefix) -> Ok (Alleles.Input.MergeFromPrefix (prefix, distance, impute))
  | (Some alignment_file), _  -> Ok (Alleles.Input.AlignmentFile (alignment_file, impute))
  | None,                None -> Error "Either a file or merge argument must be specified"

let to_filename_and_graph_args
  (* Allele information source *)
  ?alignment_file ?merge_file ~distance ~impute
  (* Allele selectors *)
    ~regex_list
    ~specific_list
    ~without_list
    ?number_alleles
  (* Graph modifiers. *)
  ~join_same_sequence ~remove_reference =
    to_input ?alignment_file ?merge_file ~distance ~impute () >>= fun input ->
      let selectors =
        regex_list @ specific_list @ without_list @
          (match number_alleles with | None -> [] | Some s -> [s])
      in
      let arg = {Ref_graph.selectors; join_same_sequence; remove_reference} in
      let graph_arg = Cache.graph_args ~arg ~input in
      let option_based_fname = Cache.graph_args_to_string graph_arg in
      Ok (option_based_fname, graph_arg)

let verbose_flag =
  let doc = "Print progress messages to stdout." in
  Arg.(value & flag & info ~doc ["v"; "verbose"])

let kmer_size_arg =
  let default = 10 in
  let docv = "POSITIVE INTEGER" in
  let doc =
    sprintf "Number of consecutive nucleotides to use consider in K-mer
              index construction. Defaults to %d." default
  in
  Arg.(value & opt positive_int default & info ~doc ~docv ["k"; "kmer-size"])

let fastq_file_arg =
  let docv = "FASTQ FILE" in
  let doc = "Fastq formatted DNA reads file, only one file per sample. \
             List paired end reads as 2 sequential files." in
  Arg.(non_empty & pos_all file [] & info ~doc ~docv [])

let num_reads_arg =
  let docv = "POSITIVE INTEGER" in
  let doc = "Number of reads to take from the front of the FASTA file" in
  Arg.(value & opt (some positive_int) None & info ~doc ~docv ["reads"])

let distance_flag =
  let open Distances in
  let d = "How to compute the distance between alleles: " in
  Arg.(value & vflag Trie
    [ Trie,        info ~doc:(d ^ "trie based off of allele names.") ["trie"]
    ; AverageExon, info ~doc:(d ^ "smallest shared exon distance.") ["ave-exon"]
    ])

let print_top_flag =
  let doc = "Print only the specified number (positive integer) of alleles" in
  Arg.(value & opt (some int) None & info ~doc ["print-top"])

let specific_read_args =
  let docv = "STRING" in
  let doc  = "Read name string (to be found in fastq) to type. Add multiple \
              to create a custom set of reads." in
  Arg.(value
      & opt_all string []
      & info ~doc ~docv ["sr"; "specific-read"])

let default_error_fname =
  "typing_errors.log"

let error_output_flag =
  let doc dest =
    sprintf "Output errors such as sequences that don't match to %s. \
              By default output is written to %s." dest default_error_fname
  in
  Arg.(value & vflag `InputPrefixed
    [ `Stdout,        info ~doc:(doc "standard output") ["error-stdout"]
    ; `Stderr,        info ~doc:(doc "standard error") ["error-stderr"]
    ; `DefaultFile,   info ~doc:(doc "default filename") ["error-default"]
    ; `InputPrefixed, info ~doc:(doc "input prefixed") ["error-input-prefixed"]
    ])

let reduce_resolution_arg =
  let doc  = "Reduce the resolution of the PDF, to a lower number of \
              \"digits\". The general HLA allele nomenclature \
              has 4 levels of specificity depending on the number of colons \
              in the name. For example A*01:01:01:01 has 4 and A*01:95 \
              has 2. This argument specifies the number (1,2,or 3) of \
              digits to reduce results to. For example, specifying 2 will \
              choose the best (depending on metric) allele out of \
              A*02:01:01:01, A*02:01:01:03, ...  A*02:01:02, ... \
              A*02:01:100 for A*02:01. The resulting set will have at most \
              the specified number of digit groups, but may have less."
  in
  let one_to_three_parser s =
    match positive_int_parser (fun x -> x) s with
    | Ok x when x = 1 || x = 2 || x = 3 -> Ok x
    | Ok x                              -> Error (`Msg (sprintf  "not 1 to 3: %d" x))
    | Error e                           -> Error e
  in
  let open Arg in
  let one_to_three = conv ~docv:"ONE,TWO or THREE"
    (one_to_three_parser , (fun frmt -> Format.fprintf frmt "%d"))
  in
  value & opt (some one_to_three) None & info ~doc ["reduce-resolution"]

let to_distance_targets_and_candidates alignment_file_opt merge_opt =
  let open Mas_parser in
  match alignment_file_opt, merge_opt with
  | _, (Some prefix) ->
      let gen = from_file (prefix ^ "_gen.txt") in
      let nuc = from_file (prefix ^ "_nuc.txt") in
      let t, c = Merge_mas.merge_mp_to_dc_inputs ~gen ~nuc in
      Ok (nuc.reference, nuc.ref_elems, t, c)
  | Some af, None ->
      let mp = from_file af in
      let targets =
        List.fold_left mp.alt_elems ~init:StringMap.empty
          ~f:(fun m (allele, alst) -> StringMap.add ~key:allele ~data:alst m)
      in
      Ok (mp.reference, mp.ref_elems, targets, targets)
  | None, None  ->
      Error "Either a file or merge argument must be specified"

