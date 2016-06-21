(* How this works:

This is a line based format. For our purposes, there are three types of lines
as determined by {type line}, where `SeqData` has most of the actual alignment
data. We divide the parsing of sequences into two types: reference and
alternatives. We take special care of keeping track of gaps in the reference so
that positions, when parsing the alternatives, are annotated with regard to
the reference positions.

We return
*)

open Printf
module String = Sosa.Native_string

let invalid_argf ?(prefix="") fmt = ksprintf invalid_arg ("%s" ^^ fmt) prefix

(* This refers to the alignment position.  *)
type position = int

let is_nucleotide = function 'A' | 'C' | 'G' | 'T' -> true | _ -> false
let is_amino_acid =
  function
  | 'A'| 'C'| 'D'| 'E'| 'F'| 'G'| 'H'| 'I'| 'K'| 'L'
  | 'M'| 'N'| 'P'| 'Q'| 'R'| 'S'| 'T'| 'V'| 'W'| 'Y' -> true
  | _ -> false

type 'e parse_struct =
  { allele    : string
  (* For now, it makes it easier to have some kind of sane delimiter to align
     and spot check these alignments. The "|" are the 'boundaries'. This keeps
     track of the most recently encountered boundary marker, starting with 0. *)
  ; boundary  : int
  (* Where we are in the sequence, this starts from the first number specified
     in the file and increments as we read characters. *)
  ; position  : position
  ; sequence  : 'e list
  ; in_data   : bool
  }

let init_ps allele position =
  { allele
  ; position
  ; boundary = 0
  ; sequence = []
  ; in_data = false
  }

let where ps =
  sprintf "allele: %s, position: %d, sequence length: %d"
    ps.allele ps.position (List.length ps.sequence)

type 'sr alignment_element =
  | Start of position
  | End of position
  | Boundary of { idx : int; pos : position }
  | Sequence of { start : position; s : 'sr }
  | Gap of { start : position; length : int }

let al_el_to_string = function
  | Start p               -> sprintf "Start at %d" p
  | End p                 -> sprintf "End at %d" p
  | Boundary { idx; pos } -> sprintf "Boundary %d at %d" idx pos
  | Sequence { start; s } -> sprintf "Sequence %s at %d" s start
  | Gap { start; length } -> sprintf "Gap of %d from %d" length start

type data_switch =
  | Data
  | NotData
  | NoEffect

let next ps ds f =
  let npos = ps.position + 1 in
  let insert_start_before_boundary = function
    | (Boundary {pos; _} as b) :: tl when pos + 1 = npos ->
             b :: (Start pos) :: tl
    | lst -> (Start npos) :: lst
  in
  let in_data, new_seq =
    match ds, ps.in_data with
    | Data,     true    -> true,       ps.sequence
    | Data,     false   -> true,       insert_start_before_boundary ps.sequence
    | NotData,  true    -> false,      (End npos) :: ps.sequence
    | NotData,  false   -> false,      ps.sequence
    | NoEffect, _       -> ps.in_data, ps.sequence
  in
  { ps with in_data; position = npos; sequence = f npos new_seq }

let insert_boundary ps =
  let nps =
    next ps NoEffect (fun position sequence ->
        Boundary { idx = ps.boundary; pos = position} :: sequence)
  in
  { nps with boundary = ps.boundary + 1 }

let insert_gap ps =
  next ps NoEffect (fun position -> function
    | Gap { start; length } :: t when start + length = position
                            -> Gap { start; length = length + 1 } :: t
    | []
    | End _ :: _
    | Start _ :: _
    | Boundary _ :: _
    | Gap _ :: _
    | Sequence _ :: _ as l  -> Gap { start = position; length = 1 } :: l)

let insert_nuc_error fmt =
  invalid_argf ~prefix:"Trying to insert sequence element " fmt

let insert_same ~fail_on_same ps =
  if fail_on_same then
    invalid_argf "Encountered unexpected '-' same char for : %s" (where ps)
  else
    next ps Data (fun _position sequence -> sequence)

let insert_nuc c ps =
  next ps Data (fun position -> function
    | Sequence {start; s} :: t when start + (List.length s) = position
                            -> Sequence { start; s = c :: s} :: t
    | []
    | End _ :: _            -> invalid_argf "Adding a Nuc %c %d %s after End or Empty!"
                                  c position ps.allele
    | Start _ :: _
    | Boundary _ :: _
    | Gap _ :: _
    | Sequence _ :: _ as l  -> Sequence { start = position; s = c :: [] } :: l )

let insert_unknown ps =
  next ps NotData (fun _position sequence -> sequence)

let update ~dna ~fail_on_same ps s =
  let is_nuc = if dna then is_nucleotide else is_amino_acid in
  let rec to_ref_seq_elems_char ps = function
    | []                    -> ps
    | '|' :: t              -> to_ref_seq_elems_char (insert_boundary ps) t
    | '*' :: t              -> to_ref_seq_elems_char (insert_unknown ps) t
    | 'X' :: t when not dna -> to_ref_seq_elems_char (insert_unknown ps) t (* add End *)
    | '.' :: t              -> to_ref_seq_elems_char (insert_gap ps) t
    | '-' :: t              -> to_ref_seq_elems_char (insert_same ~fail_on_same ps) t
    | c :: t when is_nuc c  -> to_ref_seq_elems_char (insert_nuc c ps) t
    | x :: _                -> invalid_argf "Unrecognized char %c in %s" x (where ps)
  in
  to_ref_seq_elems_char ps (String.to_character_list s)

let gaps_to_string gps =
  String.concat ~sep:";" (List.map (fun (p,l) -> sprintf "(%d,%d)" p l) gps)

type 'sr parse_result =
  { dna       : bool        (* DNA or Amino Acid sequence -> diff characters *)
  ; start_pos : position
  ; ref       : string      (* Name of reference. *)
  (* As we parse the alternative tracks, we have to Keep track of the gaps that
     we encounter in the reference, so that all positions are with respect to
     the reference. *)
  ; ref_ps    : 'sr parse_struct
  ; alg_htbl  : (string, 'sr parse_struct) Hashtbl.t
  }

let empty_result ref_allele dna position =
  { dna       = dna
  ; start_pos = position - 1
  ; ref       = ref_allele
  ; ref_ps    = init_ps ref_allele (position - 1)
  ; alg_htbl  = Hashtbl.create 100
  }

let reverse_seq lst =
  let to_string l = String.of_character_list (List.rev l) in
  List.rev lst |> List.map (function
    | Start _
    | End _
    | Boundary _
    | Gap _ as e            -> e
    | Sequence { start; s } -> Sequence { start; s = to_string s })

let normalized_seq ps =
  let rec has_end = function
    | End _ :: _      -> true
    | Boundary _ :: t -> has_end t
    | Gap _ :: t      -> has_end t
    | _               -> false
  in
  if has_end ps.sequence then
    reverse_seq ps.sequence
  else
    reverse_seq (End (ps.position + 1) :: ps.sequence)

type line =
  | Position of bool * int  (* nucleotide or amino acid sequence  *)
  | Dash
  | SeqData of string * string list

(* Assume that it has been trimmed. *)
let parse_data line =
  String.split line ~on:(`Character ' ')
  |> List.filter ((<>) String.empty)
  |> function
      | "|" :: _                -> Dash
      | "AA" :: "codon" :: _    -> Dash (* not really but not modeling this at the moment. *)
      | "gDNA" :: pos :: _      -> Position (true, int_of_string pos)
      | "cDNA" :: pos :: _      -> Position (true, int_of_string pos)
      | "Prot" :: pos :: _      -> Position (false, int_of_string pos)
      | []                      -> invalid_arg "Empty data line!"
      | s :: lst                -> SeqData (s, lst)

type parse_state =
  | Header
  | Empty
  | Data of line

type result =
  { reference : string
  ; ref_elems : string alignment_element list
  ; alt_elems : (string * string alignment_element list) list
  }

let report = ref false

let from_in_channel ic =
  (*let previous_reference_position = ref min_int in*)
  let latest_reference_position = ref min_int in
  let update x = function
    (* Sometimes, the files position counting seems to disagree with this
       internal count, usually because of multiple boundaries. Not certain
       how to get to the bottom, but my manual string counts lead me to
       believe that there isn't a bug in the parsing code. One possibility is
       that there is no '0' the position in the files; their indices are
       [-1, 1, 2].

       So we don't check for: x.ref_ps.position = p as well. *)
    | Position (dna, p) -> assert (x.dna = dna); x
    | Dash              -> x (* ignore dashes *)
    | SeqData (allele, s) ->
      if x.ref = allele then begin
        (*let prev_pos = x.ref_ps.position in *)
        let nref_ps = List.fold_left (update ~dna:x.dna ~fail_on_same:true) x.ref_ps s in
        latest_reference_position := nref_ps.position;
        { x with ref       = allele
               ; ref_ps    = nref_ps
        }
      end else begin
        let cur_ps =
          try Hashtbl.find x.alg_htbl allele
          with Not_found -> init_ps allele x.start_pos
        in
        let new_ps = List.fold_left (update ~dna:x.dna ~fail_on_same:false) cur_ps s in
        (* Can't make this into an assertion because of sequences such as
            C*04:09N that have sequences extending after the end of the
            reference. *)
        if !report
           (*&& new_ps.in_data <> After*)
           && new_ps.position <> !latest_reference_position then
          printf
            "position mismatch %d vs %d for %s.\n"
            !latest_reference_position new_ps.position new_ps.allele;
        Hashtbl.replace x.alg_htbl allele new_ps;
        x
      end
  in
  let rec loop state acc =
    match input_line ic |> String.strip ~on:`Both with
    | exception End_of_file -> acc
    | line ->
      match state with
      | Header when String.is_empty line -> loop Empty acc
      | Header                           -> loop Header acc
      | Empty  when String.is_empty line -> loop Empty acc
      | Empty                            -> if String.is_prefix line ~prefix:"Please" then
                                              acc
                                            else
                                              let d = parse_data line in
                                              loop (Data d) (update acc d)
      | Data _ when String.is_empty line -> loop Empty acc
      | Data _ ->                           let d = parse_data line in
                                            loop (Data d) (update acc d)
  in
  let rec loop_header state =
    match input_line ic |> String.strip ~on:`Both with
    | exception End_of_file -> invalid_arg "Didn't get to the data!"
    | line ->
      match state with
      | Header when String.is_empty line -> loop_header Empty
      | Header                           -> loop_header Header
      | Empty  when String.is_empty line -> loop_header Empty
      | Empty                            ->
          begin
            let d = parse_data line in
            match d with
            | Position _ -> loop_header (Data d)
            | _          -> invalid_arg "First data not position."
          end
      | Data _ when String.is_empty line -> loop_header state
      | Data (Position (dna, p)) ->
          begin
            match parse_data line with
            | SeqData (allele, _) as d -> let res = empty_result allele dna p in
                                          loop (Data d) (update res d)
            | _                        -> loop_header state
          end
      | Data _ -> loop_header state
  in
  let reversed = loop_header Header in
  let ref_elems = normalized_seq reversed.ref_ps in
  let alt_elems =
    Hashtbl.fold (fun all ps acc ->
        if ps.sequence = [] then begin
          printf "Dropping empty sequence: %s\n" ps.allele;
          acc
        end else
          (all, normalized_seq ps) :: acc)
      reversed.alg_htbl []
  in
  { reference = reversed.ref ; ref_elems ; alt_elems }

let from_file f =
  let ic = open_in f in
  try
    let r = from_in_channel ic in
    close_in ic;
    r
  with e ->
    close_in ic;
    raise e