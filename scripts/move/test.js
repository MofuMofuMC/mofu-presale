require("dotenv").config();

const cli = require("@aptos-labs/ts-sdk/dist/common/cli/index.js");

async function test() {
	const move = new cli.Move();

	await move.test({
		packageDirectoryPath: "contract",
		namedAddresses: {
			presale: process.env.MODULE_PUBLISHER_ACCOUNT_ADDRESS,
			treasury_addr: process.env.MODULE_PUBLISHER_ACCOUNT_ADDRESS,
		},
	});
}
test();
