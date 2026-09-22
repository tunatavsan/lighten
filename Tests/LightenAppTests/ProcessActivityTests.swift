import CLightenPlatform
import Testing

@Test("Process veto recognizes case variants and conservative interpreters")
func processVetoNames() {
  #expect(lighten_process_name_veto("Python", 0) == 1)
  #expect(lighten_process_name_veto("PIP3", 0) == 1)
  #expect(lighten_process_name_veto("UV", 0) == 1)
  #expect(lighten_process_name_veto("curl", 1) == 1)
  #expect(lighten_process_name_veto("ZSH", 1) == 1)
  #expect(lighten_process_name_veto("unrelated", 0) == 0)
  #expect(lighten_process_name_veto("unrelated", 1) == 0)
  #expect(lighten_process_activity(-1) == -1)
}
