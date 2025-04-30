import { Aptos, AptosConfig, type ClientConfig, Network } from "@aptos-labs/ts-sdk";
import { getAccount } from "./config";

async function main() {
	const config = new AptosConfig({
		network: Network.TESTNET,
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
				"0x9685bb3f64680f2a7f02870fd867fb98abc6bea231802f7f12e0cf330155b996::bridge::add_validator",
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
