# Turns `tailscale status --json` into a fixture with the same field names, value types,
# booleans, numbers of peers and zero/non-zero time shapes, but no identifying values.
def zt: if . == "0001-01-01T00:00:00Z" then . elif type == "string" then "2026-01-01T00:00:00Z" else . end;
def ip4(n): "100.64.0.\(n)";
def ip6(n): "fd7a:115c:a1e0::\(n)";
def prefix(n): if . == "0.0.0.0/0" or . == "::/0" then .
  elif test("^100\\.") then ip4(n) + "/32"
  elif test("^fd7a:") then ip6(n) + "/128"
  elif test(":") then "fd00:99::/64"
  else "192.168.99.0/24" end;
def peer(n): {
    ID: "nPEER\(n)CNTRL", PublicKey: "nodekey:peer\(n)", HostName: "peer\(n)",
    DNSName: "peer\(n).example-tailnet.ts.net.", OS: .OS, UserID: 10001,
    TailscaleIPs: [ip4(n), ip6(n)],
    AllowedIPs: ((.AllowedIPs // null) | if . == null then null else map(prefix(n)) end),
    PrimaryRoutes: ((.PrimaryRoutes // null) | if . == null then null else map(prefix(n)) end),
    Addrs: ((.Addrs // null) | if . == null then null else [range(length)] | map("198.51.100.\(n):41641") end),
    CurAddr: (if (.CurAddr // "") == "" then "" else "198.51.100.\(n):41641" end),
    Relay: (if (.Relay // "") == "" then "" else "zzz" end),
    PeerRelay: (if (.PeerRelay // "") == "" then "" else "198.51.100.200:7777:1" end),
    RxBytes: .RxBytes, TxBytes: .TxBytes,
    Created: (.Created | zt), LastWrite: (.LastWrite | zt), LastSeen: (.LastSeen | zt), LastHandshake: (.LastHandshake | zt),
    Online: .Online, ExitNode: .ExitNode, ExitNodeOption: .ExitNodeOption, Active: .Active,
    PeerAPIURL: ((.PeerAPIURL // null) | if . == null then null else ["http://\(ip4(n)):40000"] end),
    TaildropTarget: .TaildropTarget, NoFileSharingReason: .NoFileSharingReason,
    InNetworkMap: .InNetworkMap, InMagicSock: .InMagicSock, InEngine: .InEngine,
    NodeID: (n + 100)
  }
  + (if has("Expired") then {Expired: .Expired} else {} end)
  + (if has("KeyExpiry") then {KeyExpiry: (.KeyExpiry | zt)} else {} end)
  + (if has("Tags") then {Tags: ["tag:example"]} else {} end)
  + (if has("sshHostKeys") then {sshHostKeys: ["ssh-ed25519 AAAAredacted"]} else {} end)
  + (if has("CapMap") then {CapMap: (.CapMap | with_entries(.value = null))} else {} end)
  + (if has("Capabilities") then {Capabilities: .Capabilities} else {} end)
  | with_entries(select(.value != null or .key == "AllowedIPs"));

{
  Version: .Version, TUN: .TUN, BackendState: .BackendState, HaveNodeKey: .HaveNodeKey,
  AuthURL: (if .AuthURL == "" then "" else "https://login.tailscale.com/a/REDACTED" end),
  TailscaleIPs: [ip4(1), ip6(1)],
  Self: (.Self | peer(1) | .DNSName = "self.example-tailnet.ts.net." | .HostName = "self" | .ID = "nSELFCNTRL" | .PublicKey = "nodekey:self"),
  Health: .Health,
  MagicDNSSuffix: "example-tailnet.ts.net",
  CurrentTailnet: (if .CurrentTailnet == null then null else
    { Name: "user@example.com", StableID: "T000EXAMPLE", MagicDNSSuffix: "example-tailnet.ts.net", MagicDNSEnabled: .CurrentTailnet.MagicDNSEnabled } end),
  CertDomains: .CertDomains,
  ExtraRecords: (if .ExtraRecords == null then null else [{ Name: "extra.example-tailnet.ts.net.", Value: "100.64.0.250" }] end),
  Peer: ([.Peer | to_entries | .[] | .value] | to_entries | map(.key as $i | { key: "nodekey:peer\($i + 2)", value: (.value | peer($i + 2)) }) | from_entries),
  User: (.User | to_entries | to_entries | map({ key: "\(10001 + .key)", value: { ID: (10001 + .key), LoginName: "user\(.key + 1)@example.com", DisplayName: "Example User \(.key + 1)", ProfilePicURL: "" } }) | from_entries),
  ClientVersion: .ClientVersion
}
