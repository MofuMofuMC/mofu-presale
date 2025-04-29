import { Aptos, AptosConfig, type ClientConfig, Network } from "@aptos-labs/ts-sdk";
import { getAccount } from "./config";

async function main() {
	const clientConfig: ClientConfig = {
		API_KEY: "AG-FVEWZQTCTWH16J4DJMZOZCDP9NNN3MVM",
	};

	const config = new AptosConfig({
		network: Network.DEVNET,
		// fullnode: nodeApiUrl,
		fullnode: "https://api.devnet.aptoslabs.com/v1",
		clientConfig,
	});

	const aptos = new Aptos(config);

    // const aliceAccountBalance = await aptos.getAccountResource({
    //     accountAddress: alice.accountAddress,
    //     resourceType: COIN_STORE,
    //   });

	const account = getAccount();
	// Transfer between users
	const txn = await aptos.transaction.build.simple({
		sender: account.accountAddress,
		data: {
			function:
				"0xfd56505f04e78e0fd5f2cf10ddabf2a75548f6694f03fd1b6c5daedba17d48ca::bridge::add_validator",
			typeArguments: [],
			functionArguments: [
				Uint8Array.from(
					Buffer.from(
						"5807b7714a65b825b9abef874deb7c45904b0919461e514815585cbb0d9118cd",
						"hex",
					),
				),
			],
		},
	});

	const committedTxn = await aptos.signAndSubmitTransaction({
		signer: account,
		transaction: txn,
	});

	await aptos.waitForTransaction({ transactionHash: committedTxn.hash });
	console.log(`Committed transaction: ${committedTxn.hash}`);
}

main()
	.then(() => {})
	.catch((error) => {
		console.error("Error:", error);
	});
