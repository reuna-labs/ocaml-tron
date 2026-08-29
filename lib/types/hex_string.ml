let nibble = function
  | '0' .. '9' as c -> Some (Char.code c - Char.code '0')
  | 'a' .. 'f' as c -> Some (Char.code c - Char.code 'a' + 10)
  | 'A' .. 'F' as c -> Some (Char.code c - Char.code 'A' + 10)
  | _ -> None

let strip_0x s =
  if String.length s >= 2 && s.[0] = '0' && (s.[1] = 'x' || s.[1] = 'X') then
    String.sub s 2 (String.length s - 2)
  else s

let of_hex s =
  let s = strip_0x s in
  let n = String.length s in
  if n land 1 <> 0 then None
  else begin
    let b = Bytes.create (n / 2) in
    let rec go i =
      if i * 2 >= n then Some (Bytes.unsafe_to_string b)
      else
        match (nibble s.[i * 2], nibble s.[(i * 2) + 1]) with
        | Some hi, Some lo ->
            Bytes.set b i (Char.chr ((hi lsl 4) lor lo));
            go (i + 1)
        | _ -> None
    in
    go 0
  end

let digits = "0123456789abcdef"

let to_hex s =
  let b = Bytes.create (String.length s * 2) in
  String.iteri
    (fun i c ->
      let c = Char.code c in
      Bytes.set b (i * 2) digits.[c lsr 4];
      Bytes.set b ((i * 2) + 1) digits.[c land 0xf])
    s;
  Bytes.unsafe_to_string b
