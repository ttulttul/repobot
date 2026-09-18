import Testing
@testable import RepobotApp

struct NetworkCheckPolicyTests {
  @Test func testInitialAndDuplicateAvailabilityDoNotRequestChecks() {
    var policy = NetworkCheckPolicy()
    let wifi = NetworkCheckPolicy.State(available: true, interfaces: ["wifi:en0"], ipv4: true, ipv6: true, dns: true)
    #expect(policy.receive(wifi) == false)
    for _ in 0..<20 { #expect(policy.receive(wifi) == false) }
    var offline = wifi; offline.available = false
    #expect(policy.receive(offline) == false)
    #expect(policy.receive(offline) == false)
    #expect(policy.receive(wifi) == true)
    #expect(policy.receive(wifi) == false)
    var ethernet = wifi; ethernet.interfaces = ["wired:en5"]
    #expect(policy.receive(ethernet) == true)
    #expect(policy.receive(ethernet) == false)
    ethernet.ipv6 = false
    #expect(policy.receive(ethernet) == true)
  }
  @Test func testInitiallyOfflineRecovers() {
    var policy = NetworkCheckPolicy()
    var state = NetworkCheckPolicy.State(available: false, interfaces: [], ipv4: false, ipv6: false, dns: false)
    #expect(policy.receive(state) == false)
    state.available = true; state.interfaces = ["wifi:en0"]; state.ipv4 = true; state.dns = true
    #expect(policy.receive(state) == true)
  }
}
