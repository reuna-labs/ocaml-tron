let ok = function Ok value -> value | Error message -> Alcotest.fail message

let pp_scheme formatter = function
  | `Http -> Format.pp_print_string formatter "http"
  | `Https -> Format.pp_print_string formatter "https"

let scheme = Alcotest.testable pp_scheme ( = )

let check value expected_scheme expected_host expected_port expected_header =
  let endpoint = ok (Tron_rpc_unix.Endpoint.of_string value) in
  Alcotest.check scheme "scheme" expected_scheme
    (Tron_rpc_unix.Endpoint.scheme endpoint);
  Alcotest.(check string)
    "host" expected_host
    (Tron_rpc_unix.Endpoint.host endpoint);
  Alcotest.(check int)
    "port" expected_port
    (Tron_rpc_unix.Endpoint.port endpoint);
  Alcotest.(check string)
    "Host header" expected_header
    (Tron_rpc_unix.Endpoint.host_header endpoint)

let https_default () =
  check "https://nile.trongrid.io" `Https "nile.trongrid.io" 443
    "nile.trongrid.io"

let explicit_ports () =
  check "https://provider.example:8443/" `Https "provider.example" 8443
    "provider.example:8443";
  check "http://127.0.0.1:8090" `Http "127.0.0.1" 8090 "127.0.0.1:8090"

let rejects_ambiguous_endpoints () =
  List.iter
    (fun value ->
      match Tron_rpc_unix.Endpoint.of_string value with
      | Error _ -> ()
      | Ok _ -> Alcotest.failf "accepted %S" value)
    [
      "";
      "nile.trongrid.io";
      "ftp://provider.example";
      "https://token@provider.example";
      "https://provider.example/api";
      "https://provider.example/?token=secret";
      "https://provider.example/#fragment";
    ]

let () =
  Alcotest.run "tron endpoint"
    [
      ( "selection",
        [
          Alcotest.test_case "HTTPS default" `Quick https_default;
          Alcotest.test_case "explicit ports" `Quick explicit_ports;
          Alcotest.test_case "reject ambiguous endpoints" `Quick
            rejects_ambiguous_endpoints;
        ] );
    ]
