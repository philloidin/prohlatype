
open Util

type graph_args =
  { alignment_file  : string       (* this is really a path, basename below *)
  ; which           : Ref_graph.construct_which_args option
  ; normalize       : bool
  }

let graph_args_to_string { alignment_file; which; normalize } =
  sprintf "%s_%s_%b"
    (Filename.basename alignment_file)
    (match which with
      | None -> "All"
      | Some w -> Ref_graph.construct_which_args_to_string w)
    normalize

let dir = ".cache"

let graph_cache_dir = Filename.concat dir "graphs"

let graph =
  let dir = Filename.concat (Sys.getcwd ()) graph_cache_dir in
  disk_memoize ~dir graph_args_to_string
    (fun { alignment_file; which; normalize } ->
       Ref_graph.construct_from_file ~normalize ?which alignment_file)

type index_args =
  { k : int
  ; g : graph_args
  }

let index_args_to_string {k; g} =
  sprintf "%d_%s" k (graph_args_to_string g)

let index_cache_dir = Filename.concat dir "indices"

let graph_and_two_index =
  let dir = Filename.concat (Sys.getcwd ()) index_cache_dir in
  disk_memoize ~dir index_args_to_string
    (fun {k; g} ->
        let gr = graph g in
        let id = Index.create ~k gr in
        gr, id)
