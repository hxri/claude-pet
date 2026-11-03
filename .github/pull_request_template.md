## Description

Fix #(issue)

<!-- A summary of the change and which issue it fixes. Include the motivation and context.
List anything new that is required (tools, macOS version, permissions). -->


## Type of change

Please check the option that is related to your PR.

- [ ] Bug fix (non-breaking change which fixes an issue)
- [ ] New feature (non-breaking change which adds functionality)
- [ ] New or changed pet (a file in `pets/`)
- [ ] Breaking change (fix or feature that would make existing behavior stop working: saved settings, `control/` files, the pet spec format or the visiting protocol)
  - In this case, we recommend discussing your modification in a GitHub issue before creating the PR
- [ ] Documentation (modification for documents)

## Checklist

- [ ] I ran `./build.sh` and it builds without errors
- [ ] I ran the app with my changes (`./build.sh --restart`) and tried the feature
  - [ ] For visits or anything on the network, I tested with a second instance (`CLAUDEPET_PROFILE=test`) or a second Mac
  - [ ] For a new pet, `ClaudePet.app/Contents/MacOS/ClaudePet --check pets/<id>.json` passes and I looked at all five states (see `CLAUDE.md`)
- [ ] For anything visual, I attached a screenshot, a GIF or a `--render` image
- [ ] My code follows the style of the surrounding code
- [ ] I have performed a self-review of my own code
- [ ] I have commented my code, particularly in hard-to-understand areas
- [ ] I have made corresponding changes to the documentation (`README.md`, `CLAUDE.md`)
- [ ] My change shares no more than before with a visiting pet (name, owner, computer name, look, mood) and stores nothing outside `~/.claude/pet`
- [ ] I have checked my code and corrected any misspellings
