type 'a t = {
  path : string;
  body : Yojson.Safe.t;
  decode : Yojson.Safe.t -> ('a, string) result;
}

let make ~path ?(body = []) decode = { path; body = `Assoc body; decode }
let map f t = { t with decode = (fun j -> Result.bind (t.decode j) f) }
