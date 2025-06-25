import {
	AccountAddress,
	Aptos,
	AptosConfig,
	type ClientConfig,
	Hex,
	Network,
	U256,
} from "@aptos-labs/ts-sdk";
import { getAccount } from "./config";

const PRESALE_CONTRACT_ADDRESS = process.env.MODULE_ADDRESS;
async function main() {
	// const clientConfig: ClientConfig = {
	// 	API_KEY: "AG-FVEWZQTCTWH16J4DJMZOZCDP9NNN3MVM",
	// };

	const config = new AptosConfig({
		network: Network.TESTNET,
		// clientConfig,
	});

	const aptos = new Aptos(config);

	const account = getAccount();

	// 0xc5a5732db6cbb0407852fe98a515b1c83922091bc6bf21803d91eeb196f08f9d
	// 0x8919974883ea656fa4ba059819573b55b55b09850cb723aba96b76c468d09645
	const txn = await aptos.transaction.build.simple({
		sender: account.accountAddress,
		data: {
			function:
				`${PRESALE_CONTRACT_ADDRESS}::presale::add_to_whitelist`,
			typeArguments: [],
			functionArguments: [
				AccountAddress.from("0x30ff8dca978a711b19730eb767a79377023390899e5c3b07c7e6e245a4998874")
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
