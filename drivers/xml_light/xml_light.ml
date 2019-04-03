(* Xml driver for ppx_protocol_conv *)
open StdLabels
open Protocol_conv.Runtime
type t = Xml.xml

let _log fmt = Printf.eprintf (fmt ^^ "\n%!")

module StringMap = Map.Make(String)

exception Protocol_error of string * t option
(* Register exception printer *)
let () = Printexc.register_printer
    (function Protocol_error (s, Some t) -> Some (s ^ ": " ^ (Xml.to_string t))
            | Protocol_error (s, None) -> Some (s)
            | _ -> None)

let raise_errorf t fmt =
  Printf.kprintf (fun s -> raise (Protocol_error (s, t))) fmt

let to_string_hum xml =
  Xml.to_string_fmt xml

let rec element_to_map m = function
  | (Xml.Element(name, _, _) as x) :: xs ->
    let m =
      let ks = try StringMap.find name m with Not_found -> [] in
      StringMap.add name (x :: ks) m
    in
    element_to_map m xs
  | _ :: xs -> element_to_map m xs
  | [] -> m

let element name t = Xml.Element (name, [], t)

let wrap f t x = try f x with Helper.Protocol_error s -> raise_errorf (Some t) "%s" s

let record_to_xml assoc =
  List.map ~f:(
    function
    | (field, Xml.Element ("record", attrs, xs)) -> [Xml.Element (field, attrs, xs)]
    | (field, Xml.Element ("variant", attrs, xs)) -> [Xml.Element (field, attrs, xs)]
    | (field, Xml.Element ("__option", attrs, xs)) -> [Xml.Element (field, attrs, xs)]
    | (field, Xml.Element (_, _, xs)) ->
      List.map ~f:(function
          | Xml.Element(_, attrs, xs) -> Xml.Element(field, attrs, xs)
          | PCData _ as p -> Xml.Element(field, [], [p])
        ) xs (* why xs here. Or do we need to extend the option one level *)
    | (field, e) -> raise_errorf (Some e) "Must be an element: %s" field
  ) assoc
  |> List.flatten |> element "record"

let xml_to_record = function
  | Xml.Element (_, _, xs) ->
    let map = element_to_map StringMap.empty xs in
    StringMap.bindings map
    |> List.map ~f:(function
        | field, [ Xml.Element (name, _, xs) ] -> field, Xml.Element (name, ["record", "unwrapped"], xs)
        | field, [ Xml.PCData _ as d ] -> field, d
        | field, xs -> field, Xml.Element (field, [], List.rev xs)
      )
    |> (fun x -> Some x)
  | _ -> None


(* We need to create a record. Dont we have a function for that?? *)
let of_variant: string -> (t, 'a, t) Variant_out.t -> 'a = fun name spec ->
  (*
  let rewrite: type a. (t, a, t) Variant_out.t -> (t, a, t) Variant_out.t = function
    | Variant_out.Tuple Tuple_out.Nil -> Variant_out.Tuple Tuple_out.Nil
    | Variant_out.Tuple spec ->
      let rec inner: type a. int -> (t, a, t) Tuple_out.t ->  (t, a, t) Record_out.t = fun cnt -> function
        | Tuple_out.Cons (f, fs) -> Record_out.Cons ((Printf.sprintf "t%d" cnt, f, None), inner (cnt+1) fs)
        | Tuple_out.Nil -> Record_out.Nil
      in
      Variant_out.Record (inner 0 spec)
    | Variant_out.Record spec -> Variant_out.Record spec
  in
  let spec = rewrite spec in
  *)

  let to_t = function
    | Helper.Nil -> Xml.Element("variant", [], [Xml.PCData name])
    | Helper.Tuple l -> Xml.Element("variant", [], Xml.PCData name :: l)
    | Helper.Record r -> Xml.Element("variant", [], [Xml.PCData name; (record_to_xml r)])
  in
  Helper.of_variant to_t spec

let to_variant: (string * (t, 'c) Variant_in.t) list -> t -> 'c = fun spec ->
  (*
  let rewrite spec =
    let inner: type c. (t, c) Variant_in.t -> (t, c) Variant_in.t = function
      | Variant_in.Tuple (Tuple_in.Nil, b) -> Variant_in.Tuple (Tuple_in.Nil, b)
      | Variant_in.Tuple (spec, b) ->
      let rec inner: type a b. int -> (t, a, b) Tuple_in.t -> (t, a, b) Record_in.t = fun cnt -> function
        | Tuple_in.Cons (f, fs) -> Record_in.Cons ((Printf.sprintf "t%d" cnt, f, None), inner (cnt+1) fs)
        | Tuple_in.Nil -> Record_in.Nil
      in
      Variant_in.Record ((inner 0 spec), b)
    | Variant_in.Record (spec, b) -> Variant_in.Record (spec, b)
    in
    List.map ~f:(fun (field, spec) -> (field, inner spec)) spec
  in
  let spec = rewrite spec in
  *)
  let f = Helper.to_variant xml_to_record spec in
  function
  | Xml.Element(_, _, Xml.PCData s :: es) as t ->
    begin try f s es with Helper.Protocol_error s -> raise_errorf (Some t) "%s" s end
  | Xml.Element(name, _, []) as t -> raise_errorf (Some t) "No contents for variant type: %s" name
  | t -> raise_errorf (Some t) "Wrong variant data"

let to_record: type a b. (t, a, b) Record_in.t -> a -> t -> b = fun spec constr->
  let f = Helper.to_record ~default:(Xml.Element ("", [], [])) spec constr in
  fun t -> match xml_to_record t with
    | Some ts -> wrap f t ts
    | None -> raise_errorf (Some t) "Expected record"

let of_record: type a. (t, a, t) Record_out.t -> a = fun spec ->
  Helper.of_record record_to_xml spec

let of_tuple: (t, 'a, t) Tuple_out.t -> 'a = fun spec ->
  let rec inner: type a b c. int -> (a, b, c) Tuple_out.t -> (a, b, c) Record_out.t = fun i -> function
    | Tuple_out.Cons (f, xs) ->
      let tail = inner (i+1) xs in
      Record_out.Cons ( (Printf.sprintf "t%d" i, f, None), tail)
    | Tuple_out.Nil -> Record_out.Nil
  in
  of_record (inner 0 spec)

let to_tuple: type constr b. (t, constr, b) Tuple_in.t -> constr -> t -> b = fun spec constr ->
  let rec inner: type a b c. int -> (a, b, c) Tuple_in.t -> (a, b, c) Record_in.t = fun i -> function
    | Tuple_in.Cons (f, xs) ->
      let tail = inner (i+1) xs in
      Record_in.Cons ( (Printf.sprintf "t%d" i, f, None), tail)
    | Tuple_in.Nil -> Record_in.Nil
  in
  let spec = inner 0 spec in
  to_record spec constr

let to_option: (t -> 'a) -> t -> 'a option = fun to_value_fun t ->
  (* Not allowed to throw out the unwrap. *)
  match t with
  | Xml.Element (_, [_, "unwrapped"], [])
  | Xml.Element (_, _, [])
  | Xml.Element (_, _, [ PCData ""] ) ->
    None
  | Xml.Element (_, [_, "unwrapped"], [ (Element ("__option", _, _) as t)])
  (*  | Xml.Element (_, [_, "unwrapped"], [ t ]) *)
  | Xml.Element ("__option", _, [t])
  | t ->
    Some (to_value_fun t)

(* Some Some None ->
   Some Some Some v -> v
*)

let of_option: ('a -> t) -> 'a option -> t = fun of_value_fun v ->
  let t = match v with
    | None ->
      Xml.Element ("__option", [], [])
    | Some x -> begin
      match of_value_fun x with
        | (Xml.Element ("__option", _, _) as t) ->
          Xml.Element ("__option", [], [t])
        | t ->
          t
    end
  in
  t

let to_ref: (t -> 'a) -> t -> 'a ref = fun to_value_fun t ->
  let v = to_value_fun t in
  ref v

let of_ref: ('a -> t) -> 'a ref -> t = fun of_value_fun v ->
  of_value_fun !v


(** If the given list has been unwrapped since its part of a record, we "rewrap it". *)
let to_list: (t -> 'a) -> t -> 'a list = fun to_value_fun -> function
  | Xml.Element (_, [_, "unwrapped"], _) as elm ->
    (* If the given list has been unwrapped since its part of a record, we "rewrap it". *)
    [ to_value_fun elm ]
  | Xml.Element (_, _, ts) ->
    List.map ~f:(fun t -> to_value_fun t) ts
  | e -> raise_errorf (Some e) "Must be an element type"

let of_list: ('a -> t) -> 'a list -> t = fun of_value_fun vs ->
  Xml.Element("l", [], List.map ~f:(fun v -> of_value_fun v) vs)

let to_array: (t -> 'a) -> t -> 'a array = fun to_value_fun t ->
  to_list to_value_fun t |> Array.of_list

let of_array: ('a -> t) -> 'a array -> t = fun of_value_fun vs ->
  of_list of_value_fun (Array.to_list vs)

let to_lazy_t: (t -> 'a) -> t -> 'a lazy_t = fun to_value_fun t -> Lazy.from_fun (fun () -> to_value_fun t)

let of_lazy_t: ('a -> t) -> 'a lazy_t -> t = fun of_value_fun v ->
  Lazy.force v |> of_value_fun


let of_value to_string v = Xml.Element ("p", [], [ Xml.PCData (to_string v) ])
let to_value type_name of_string = function
  | Xml.Element(_, _, []) -> of_string ""
  | Xml.Element(_, _, [PCData s]) -> of_string s
  | Xml.Element(name, _, _) as e -> raise_errorf (Some e) "Primitive value expected in node: %s for %s" name type_name
  | Xml.PCData _ as e -> raise_errorf (Some e) "Primitive type not expected here when deserializing %s" type_name

let to_bool = to_value "bool" bool_of_string
let of_bool = of_value string_of_bool

let to_int = to_value "int" int_of_string
let of_int = of_value string_of_int

let to_int32 = to_value "int32" Int32.of_string
let of_int32 = of_value Int32.to_string

let to_int64 = to_value "int64" Int64.of_string
let of_int64 = of_value Int64.to_string

let to_float = to_value "float" float_of_string
let of_float = of_value string_of_float

let to_string = to_value "string" (fun x -> x)
let of_string = of_value (fun x -> x)

let to_char = to_value "char" (function s when String.length s = 1 -> s.[0]
                                      | s -> raise_errorf None "Expected char, got %s" s)
let of_char = of_value (fun c -> (String.make 1 c))



let to_unit = to_value "unit" (function "()" -> () | _ -> raise_errorf None "Expected char")
let of_unit = of_value (fun () -> "()")

(*
let to_unit t = to_tuple Nil () t
let of_unit () = of_tuple []
*)
    (*
let to_unit = function Xml.Element (_, _, [ PCData "unit" ]) -> ()
                     | e -> raise_errorf e "Unit must be 'unit'"

let of_unit () = Xml.Element ("u", [], [ PCData "unit" ])
*)
let of_xml_light t = t
let to_xml_light t = t
