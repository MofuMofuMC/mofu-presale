import { Account, Ed25519PrivateKey } from "@aptos-labs/ts-sdk";
import "dotenv/config";

if (!process.env.ACCOUNT_PRIVATE_KEY) {
	throw new Error(
		"ACCOUNT_PRIVATE_KEY variable is not set, make sure you have set the publisher account private key",
	);
}

export const getAccount = () => {
	const privateKey = new Ed25519PrivateKey(
		process.env.ACCOUNT_PRIVATE_KEY as string,
	);
	const account = Account.fromPrivateKey({ privateKey });


  
	return account;
};
