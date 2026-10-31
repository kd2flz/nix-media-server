## Summary

<!-- What changed and why -->

## Testing checklist

- [ ] `./tests/run-all.sh` passes locally
- [ ] Added/updated the test that covers this change (see AGENTS.md "Testing requirements")
- [ ] No hostnames hardcoded in tests
- [ ] Read the `deploy-impact` comment: reboots? service restarts? secrets changes?
- [ ] If a reboot is flagged: held until a maintenance window, then added the `approved-for-downtime` label
- [ ] Anything the tests cannot cover was verified on T29769 via `dev` (note what you checked)
