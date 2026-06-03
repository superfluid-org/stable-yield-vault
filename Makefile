.PHONY: echidna-smoke echidna-long echidna-clean echidna-sync-smoke echidna-sync-long

ECHIDNA_TARGET := test/echidna/EchidnaStableYieldVault.sol
ECHIDNA_CONTRACT := EchidnaStableYieldVault
ECHIDNA_SYNC_TARGET := test/echidna/EchidnaStableYieldSyncVault.sol
ECHIDNA_SYNC_CONTRACT := EchidnaStableYieldSyncVault
ECHIDNA_ENV := FOUNDRY_PROFILE=echidna

echidna-smoke:
	$(ECHIDNA_ENV) echidna $(ECHIDNA_TARGET) --contract $(ECHIDNA_CONTRACT) --config echidna.yaml

echidna-long:
	$(ECHIDNA_ENV) echidna $(ECHIDNA_TARGET) --contract $(ECHIDNA_CONTRACT) --config echidna.yaml \
		--test-limit 1000000 --seq-len 100

echidna-sync-smoke:
	$(ECHIDNA_ENV) echidna $(ECHIDNA_SYNC_TARGET) --contract $(ECHIDNA_SYNC_CONTRACT) --config echidna.sync.yaml

echidna-sync-long:
	$(ECHIDNA_ENV) echidna $(ECHIDNA_SYNC_TARGET) --contract $(ECHIDNA_SYNC_CONTRACT) --config echidna.sync.yaml \
		--test-limit 1000000 --seq-len 100

echidna-clean:
	rm -rf echidna-corpus echidna-corpus-sync echidna-coverage crytic-export
