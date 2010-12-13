open Ocamlbuild_plugin
open Command
open Ocamlbuild_pack.Ocaml_compiler
open Ocamlbuild_pack.Ocaml_utils
open Ocamlbuild_pack.Tools

let ps = Printf.sprintf

(* This decides the global OS backend. It could be moved into explicit
   dependencies in the future, but for now is set as an environment
   variable *)
let os =
  let os = getenv "MIRAGEOS" ~default:"unix" in
  if os <> "unix" && os <> "xen" then
    (Printf.eprintf "`%s` is not a supported OS\n" os; exit (-1))
  else
    (Ocamlbuild_pack.Log.dprintf 0 "OS: %s" os; os)

(* Points to the root of the installed Mirage stdlibs *)
let lib = getenv "MIRAGELIB"

let stdlib = ps "%s/std/lib" lib
let oslib = ps "%s/os/%s" lib os
let cowlib = ps "%s/cow/lib" lib
let netlib = ps "%s/net" oslib
let xenlib = ps "%s/os/xen" lib

(* Utility functions (e.g. to execute a command and return lines read) *)
module Util = struct
  let split s ch =
    let x = ref [] in
    let rec go s =
      let pos = String.index s ch in
      x := (String.before s pos)::!x;
      go (String.after s (pos + 1))
    in
    try
      go s
    with Not_found -> !x

    let split_nl s = split s '\n'

    let run_and_read x = List.hd (split_nl (Ocamlbuild_pack.My_unix.run_and_read x))
end

(* OS detection *)
module OS = struct

  type u = Linux | Darwin
  type t = Unix of u | Xen
  let host = match String.lowercase (Util.run_and_read "uname -s") with
    | "linux" -> Unix Linux
    | "darwin" -> Unix Darwin
    | os -> Printf.eprintf "`%s` is not a supported host OS\n" os; exit (-1)
  let target = match String.lowercase os with
    | "unix" -> host (* Map the target to the current host, as cross-compiling is no use *)
    | "xen" -> Xen
    | x -> failwith ("unknown target os: " ^ x)
end

(* Rules for MIR *)
module Mir = struct

  let link_from_file link modules_file cmX env build =
    let modules_file = env modules_file in
    let contents_list = string_list_of_file modules_file in
    link contents_list cmX env build

  let ocamlopt_link flag tags deps out =
    Cmd (S [!Options.ocamlopt; flag; T tags;
            atomize_paths deps; A"-o"; Px out])

  let native_output_obj =
    ocamlopt_link (A"-output-obj")

  let native_output_obj_tags tags =
    tags++"ocaml"++"link"++"native"++"library"

  let native_output_obj_modules =
    link_modules [("cmx",[!Options.ext_obj])] "cmx" "o"
      !Options.ext_lib native_output_obj native_output_obj_tags

  let native_output_obj_mir =
    link_from_file native_output_obj_modules

  let cc = ref (A"cc")
  let ld = ref (A"ld")
  let ocamlc_libdir = "-L" ^ (Lazy.force stdlib_dir)
  let oslib_unixrun = oslib ^ "/libunixrun.a"
  let oslib_unixmain = oslib ^ "/main.o"

  let cc_unix_link tags arg out =
    let dl_libs = match OS.host with
      |OS.Xen -> assert false
      |OS.Unix OS.Linux -> [A"-lm"; A"-ldl"; A"-lasmrun"; A"-lcamlstr"]
      |OS.Unix OS.Darwin ->  [A"-lm"; A"-lasmrun"; A"-lcamlstr"] in
    let tags = tags++"cc"++"c" in
    Cmd (S (!cc :: [ T(tags++"link");
             A ocamlc_libdir;
             A"-o"; Px out; P arg;
             A oslib_unixrun;
             A oslib_unixmain] @ dl_libs))

  let cc_xen_link tags arg out =
    let head_obj = Px (xenlib / "x86_64.o") in
    let ldlibs = List.map (fun x -> Px (xenlib / ("lib" ^ x ^ ".a")))
      ["ocaml"; "xen"; "xencaml"; "diet"; "m"] in
    Cmd (S ( !ld :: [ T(tags++"link"++"xen");
      A"-d"; A"-nostdlib"; A"-m"; A"elf_x86_64"; A"-T";
      Px (xenlib / "mirage-x86_64.lds"); head_obj; P arg ]
      @ ldlibs @ [A"-o"; Px out]))
 
  let cc_link_c_implem ?tag c o env build =
    let c = env c and o = env o in
    let fn = match OS.target with
      | OS.Unix _ -> cc_unix_link
      | OS.Xen -> cc_xen_link in
    fn (tags_of_pathname c++"implem"+++tag) c o

  let () =
    rule "output-obj: mir -> o"
      ~prod:"%.m.o"
      ~dep:"%.mir"
      (native_output_obj_mir "%.mir" "%.m.o");

    rule "final link: m.o -> .bin"
      ~prod:"%.bin"
      ~dep:"%.m.o"
      (cc_link_c_implem "%.m.o" "%.bin")

end

let _ = dispatch begin function
  | After_rules ->
    let pa_std = ps "-I %s/std/syntax pa_ulex.cmo pa_lwt.cmo" lib in
    let pa_quotations = "-I +camlp4 -parser Camlp4QuotationCommon -parser Camlp4OCamlRevisedQuotationExpander" in
    let pa_dyntype = ps "%s -I %s/dyntype/syntax pa_type_conv.cmo dyntype.cmo pa_dyntype.cmo" pa_quotations lib in
    let pa_cow = ps "%s -I %s/cow/syntax str.cma pa_cow.cmo" pa_dyntype lib in
    let pp_pa = ps "camlp4o %s %s" pa_std pa_cow in
    let net_libs = match OS.target with
     | OS.Xen -> []
     | _ -> [ A "net.cmxa" ] in
    let cow_libs = match OS.target with
     | OS.Xen -> []
     | _ -> [ A "cow.cmx" ] in
    let libs = [
      (* std libs *) A "stdlib.cmxa"; A "lwt.cmxa"; A "ulex.cmxa";
      (* os lib *)   A "oS.cmxa";
    ] @ net_libs @ cow_libs in
    let mirage_flags = [
      A"-nostdlib"; A"-I"; A stdlib;
      A"-I"; A oslib;
      A"-I"; A netlib;
      A"-I"; A cowlib;
      A"-pp"; A pp_pa ] in

    (* do not compile and pack with the standard lib *)
    flag ["ocaml"; "compile"; "nostdlib"] & A"-nostdlib";
    flag ["ocaml"; "pack"; "nostdlib"] & A"-nostdlib";

    (* Configure the mirage lib *)
    flag ["ocaml"; "compile"] & S mirage_flags;
    flag ["ocaml"; "pack"]    & S mirage_flags;
    flag ["ocaml"; "link"]    & S (mirage_flags @ libs);
    flag ["ocamldep"]         & S[A"-pp"; A pp_pa];

    (* use pa_mirage syntax extension *)
    flag ["ocaml"; "compile"] & S[A"-pp"; A pp_pa];

  | _ -> ()
end
