import {
	AccountAddress,
	Aptos,
	AptosConfig,
	type ClientConfig,
	Hex,
	MoveString,
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

	const txn = await aptos.transaction.build.simple({
		sender: account.accountAddress,
		data: {
			function:
				`${PRESALE_CONTRACT_ADDRESS}::presale::set_accepted_coin_type`,
			typeArguments: [],
			functionArguments: [
				new MoveString("0x69091fbab5f7d635ee7ac5098cf0c1efbe31d68fec0f2cd565e8d168daf52832"),
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
