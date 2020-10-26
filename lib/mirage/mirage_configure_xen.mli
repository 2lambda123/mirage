open Functoria

module Substitutions : sig
  type v =
    | Name
    | Kernel
    | Memory
    | Block of Mirage_impl_block.block_t
    | Network of string

  type t = (v * string) list

  val lookup : t -> v -> string

  val defaults : Functoria.Info.t -> t
end

val configure_main_xl :
  ?substitutions:Substitutions.t ->
  ext:string ->
  Functoria.Info.t ->
  unit Action.t

val clean_main_xl : name:string -> ext:string -> unit Action.t

val clean_main_xe : name:string -> unit Action.t

val files : Info.t -> Fpath.t list
