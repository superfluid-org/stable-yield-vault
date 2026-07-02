.PHONY: echidna-async-smoke echidna-async-long echidna-sync-smoke echidna-sync-long echidna-clean fork-test

# Base-mainnet fork suite (override the RPC with BASE_RPC_URL, pin with BASE_FORK_BLOCK_NUMBER)
fork-test:
	SKIP_FORK_TESTS=false forge test --match-contract BaseSyncVaultForkTest -vvv

ECHIDNA_ASYNC_TARGET := test/echidna/EchidnaStableYieldAsyncVault.sol
ECHIDNA_ASYNC_CONTRACT := EchidnaStableYieldAsyncVault
ECHIDNA_SYNC_TARGET := test/echidna/EchidnaStableYieldSyncVault.sol
ECHIDNA_SYNC_CONTRACT := EchidnaStableYieldSyncVault
ECHIDNA_ENV := FOUNDRY_PROFILE=echidna

echidna-async-smoke:
	$(ECHIDNA_ENV) echidna $(ECHIDNA_ASYNC_TARGET) --contract $(ECHIDNA_ASYNC_CONTRACT) --config echidna.async.yaml

echidna-async-long:
	$(ECHIDNA_ENV) echidna $(ECHIDNA_ASYNC_TARGET) --contract $(ECHIDNA_ASYNC_CONTRACT) --config echidna.async.yaml \
		--test-limit 1000000 --seq-len 100

echidna-sync-smoke:
	$(ECHIDNA_ENV) echidna $(ECHIDNA_SYNC_TARGET) --contract $(ECHIDNA_SYNC_CONTRACT) --config echidna.sync.yaml

echidna-sync-long:
	$(ECHIDNA_ENV) echidna $(ECHIDNA_SYNC_TARGET) --contract $(ECHIDNA_SYNC_CONTRACT) --config echidna.sync.yaml \
		--test-limit 1000000 --seq-len 100

echidna-clean:
	rm -rf echidna-corpus echidna-coverage crytic-export
