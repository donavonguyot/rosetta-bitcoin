let ensure_dir path =
  let rec loop current parts =
    match parts with
    | [] -> ()
    | part :: rest ->
        let next = if current = "" then part else Filename.concat current part in
        if next <> "" && not (Sys.file_exists next) then Unix.mkdir next 0o755;
        loop next rest
  in
  let is_abs = String.length path > 0 && path.[0] = '/' in
  let parts = path |> String.split_on_char '/' |> List.filter (fun part -> part <> "") in
  loop (if is_abs then "/" else "") parts

let read_file path =
  let ic = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () ->
      let len = in_channel_length ic in
      really_input_string ic len)

let write_file path content =
  let dir = Filename.dirname path in
  if dir <> "." then ensure_dir dir;
  let oc = open_out_bin path in
  Fun.protect ~finally:(fun () -> close_out_noerr oc) (fun () -> output_string oc content)

let nibble = function
  | '0' .. '9' as c -> Char.code c - Char.code '0'
  | 'a' .. 'f' as c -> Char.code c - Char.code 'a' + 10
  | 'A' .. 'F' as c -> Char.code c - Char.code 'A' + 10
  | c -> invalid_arg (Printf.sprintf "invalid hex character: %c" c)

let bytes_of_hex hex =
  let len = String.length hex in
  if len mod 2 <> 0 then invalid_arg "hex string must have even length";
  String.init (len / 2) (fun i ->
    Char.chr ((nibble hex.[i * 2] lsl 4) lor nibble hex.[(i * 2) + 1]))

let hex_of_bytes bytes =
  let alphabet = "0123456789abcdef" in
  let out = Bytes.create (String.length bytes * 2) in
  String.iteri
    (fun i c ->
      let value = Char.code c in
      Bytes.set out (i * 2) alphabet.[value lsr 4];
      Bytes.set out ((i * 2) + 1) alphabet.[value land 0x0f])
    bytes;
  Bytes.unsafe_to_string out

let sha256_hex content = Digestif.SHA256.(to_hex (digest_string content))

let sha256_raw content = Digestif.SHA256.(to_raw_string (digest_string content))

let utc_now () =
  let tm = Unix.gmtime (Unix.time ()) in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ"
    (tm.tm_year + 1900) (tm.tm_mon + 1) tm.tm_mday tm.tm_hour tm.tm_min tm.tm_sec

let today_utc () =
  let tm = Unix.gmtime (Unix.time ()) in
  Printf.sprintf "%04d-%02d-%02d" (tm.tm_year + 1900) (tm.tm_mon + 1) tm.tm_mday

let command_output command =
  let ic = Unix.open_process_in command in
  Fun.protect
    ~finally:(fun () -> ignore (Unix.close_process_in ic))
    (fun () ->
      try String.trim (input_line ic) with End_of_file -> "unknown")

let git_commit () =
  try
    let value = command_output "git rev-parse --short HEAD 2>/dev/null" in
    if value = "" then "unknown" else value
  with _ -> "unknown"

let yojson_to_file path json =
  write_file path (Yojson.Safe.pretty_to_string json ^ "\n")

let json_member name json =
  match json with
  | `Assoc fields -> List.assoc_opt name fields
  | _ -> None

let json_string name json =
  match json_member name json with
  | Some (`String value) -> value
  | _ -> ""

let json_int name json =
  match json_member name json with
  | Some (`Int value) -> value
  | Some (`Intlit value) -> int_of_string value
  | _ -> 0

let json_list name json =
  match json_member name json with
  | Some (`List rows) -> rows
  | _ -> []

