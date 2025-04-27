module bridge::mofu_nft {
    use std::error;
    // use std::vector;
    use std::string::{Self, String};
    use std::option::{Self};
    // use aptos_framework::aggregator_v2::{Self, Aggregator};
    use aptos_framework::object::{Self, Object};
    use aptos_token_objects::collection::{Self};
    use aptos_token_objects::token::{Self};
    use std::signer;
    use aptos_std::string_utils;

    // ======== Constants ========

    const COLLECTION_NAME: vector<u8> = b"Mofu Mofu Music Caravan";
    const METADATA_URI: vector<u8> = b"https://bafybeiekgc2nuuwsr3vp5rvepp3kidytatzydrtjztvhpkyjweiknseg5u.ipfs.nftstorage.link/";
    const COLLECTION_MAX_SUPPLY: u64 = 500;
    const COLLECTION_DESCRIPTION: vector<u8> = b"MOFUMOFU";
    const COLLECTION_URI: vector<u8> = b"https://mmmc.toho.co.jp";

    // ======== Errors ========

    const ETOKEN_DOES_NOT_EXIST: u64 = 1;
    const ENOT_CREATOR: u64 = 2;
    const EMISMATCH_TOKEN_ID: u64 = 3;
    // ========= Structs =========

    // #[resource_group_member(group = aptos_framework::object::ObjectGroup)]
    // /// A struct holding items to control properties of a collection
    // struct MofuCollection has key {
    //     extend_ref: object::ExtendRef,
    //     mutator_ref: collection::MutatorRef
    // }

    // #[resource_group_member(group = aptos_framework::object::ObjectGroup)]
    // /// A struct that contains the owner of the collection for others to mint
    // struct CollectionOwner has key {
    //     extend_ref: object::ExtendRef
    // }

    #[resource_group_member(group = aptos_framework::object::ObjectGroup)]
    /// A struct holding items to control properties of a token
    struct MofuToken has key {
        /// Used to mutate the token.
        // mutator_ref: token::MutatorRef,
        /// Used to burn.
        burn_ref: token::BurnRef
    }

    // ======== Public Package Functions ========

    public(package) fun mint_token(creator: &signer, token_id: u256): address {
        // let caller_address = signer::address_of(creator);
        // let collection_address = collection_owner();
        // let collection_owner = borrow_global<CollectionOwner>(collection_address);
        // let owner_extend_ref = &collection_owner.extend_ref;
        // let owner_signer = object::generate_signer_for_extending(owner_extend_ref);
        let metadata_uri = token_uri(METADATA_URI, token_id);

        let constructor_ref =
            token::create_numbered_token(
                creator,
                string::utf8(COLLECTION_NAME),
                string::utf8(b""), // Description
                string::utf8(b"Mofu #"), // Prefix
                string::utf8(b""),
                option::none(), // No royalty
                metadata_uri
            );
        // Save references to allow for modifying the NFT after minting
        // let extend_ref = object::generate_extend_ref(&constructor_ref);
        // let mutator_ref = token::generate_mutator_ref(&constructor_ref);
        let burn_ref = token::generate_burn_ref(&constructor_ref);
        let object_signer = object::generate_signer(&constructor_ref);
        // let transfer_ref = object::generate_transfer_ref(&constructor_ref);

        let mofu_token = MofuToken { burn_ref };

        move_to(&object_signer, mofu_token);

        // Transfer NFT to the caller
        let token_object =
            object::object_from_constructor_ref<MofuToken>(&constructor_ref);

        // debug::print(&b"Token object: ");
        // debug::print(&token::index(token_object));
        // debug::print(&token_id);
        assert!(
            (token::index(token_object) - 1) == (token_id as u64),
            error::invalid_state(EMISMATCH_TOKEN_ID)
        );
        let token_address = object::object_address(&token_object);
        // object::transfer(&object_signer, token_object, caller_address);

        token_address
    }

    public(package) inline fun create_mofu_collection(creator: &signer) {
        let description = string::utf8(COLLECTION_DESCRIPTION);
        let name = string::utf8(COLLECTION_NAME);
        let uri = string::utf8(COLLECTION_URI);

        collection::create_fixed_collection(
            creator,
            description,
            COLLECTION_MAX_SUPPLY,
            name,
            option::none(), // No royalty
            uri
        );
        // let constructor_ref =
        //     collection::create_fixed_collection(
        //         owner,
        //         description,
        //         COLLECTION_MAX_SUPPLY,
        //         string::utf8(COLLECTION_NAME),
        //         option::none(), // No royalty
        //         collection_uri
        //     );

        // let extend_ref = object::generate_extend_ref(&constructor_ref);
        // let mutator_ref = collection::generate_mutator_ref(&constructor_ref);

        // let object_signer = object::generate_signer(&constructor_ref);
        // move_to(&object_signer, MofuCollection { extend_ref, mutator_ref });
    }

    inline fun token_uri(base_uri: vector<u8>, token_id: u256): String {
        let uri = string::utf8(base_uri);
        string::append(&mut uri, string_utils::to_string(&token_id));
        string::append(&mut uri, string::utf8(b".json"));
        uri
    }

    // ======= Private Functions ========
    // ======= Views ========

    // #[view]
    // public fun total_minted(): AggregatorSnapshot<u64> {
    //     let collection_address = collection_owner();
    //     // let collection = object::address_to_object<collection::Collection>(collection_address);
    //     // collection::index(collection)

    //     let supply = borrow_global_mut<collection::ConcurrentSupply>(collection_address);
    //     aggregator_v2::snapshot(&supply.total_minted)
    // }

    #[view]
    public fun collection_owner(): address {
        object::create_object_address(
            &@bridge,
            collection::create_collection_seed(&string::utf8(COLLECTION_NAME))
        )
    }

    inline fun authorized_borrow<T: key>(
        token: &Object<T>, creator: &signer
    ): &MofuToken {
        let token_address = object::object_address(token);
        assert!(
            exists<MofuToken>(token_address),
            error::not_found(ETOKEN_DOES_NOT_EXIST)
        );

        assert!(
            token::creator(*token) == signer::address_of(creator),
            error::permission_denied(ENOT_CREATOR)
        );
        &MofuToken[token_address]
    }

    // inline fun collection_address(creator: &signer, name: &String): address {
    //     collection::create_collection_address(&signer::address_of(creator), name)

    // }

    // inline fun collection_object(creator: &signer, name: &String): Object<MofuCollection> {
    //     let collection_addr = collection::create_collection_address(&signer::address_of(creator), name);
    //     object::address_to_object<MofuCollection>(collection_addr)
    // }

    // ======= Tests ========

    #[test_only]
    fun create_mofu_collection_for_testing(creator: &signer) {
        let description = string::utf8(COLLECTION_DESCRIPTION);
        // let name = string::utf8(COLLECTION_NAME);
        let uri = string::utf8(COLLECTION_URI);

        collection::create_fixed_collection(
            creator,
            description,
            5,
            string::utf8(COLLECTION_NAME),
            option::none(), // No royalty
            uri
        );
    }

    #[test]
    fun test_token_uri() {
        let base_uri =
            b"https://bafybeiekgc2nuuwsr3vp5rvepp3kidytatzydrtjztvhpkyjweiknseg5u.ipfs.nftstorage.link/";
        let token_id = 1;
        let expected_uri =
            string::utf8(
                b"https://bafybeiekgc2nuuwsr3vp5rvepp3kidytatzydrtjztvhpkyjweiknseg5u.ipfs.nftstorage.link/1.json"
            );
        let result = token_uri(base_uri, token_id);
        assert!(result == expected_uri);
    }

    #[test(creator = @bridge)]
    fun test_create_nft_collection(creator: &signer) {
        create_mofu_collection(creator);

        let collection_name = string::utf8(COLLECTION_NAME);
        let collection_address =
            collection::create_collection_address(
                &signer::address_of(creator), &collection_name
            );
        let collection =
            object::address_to_object<collection::Collection>(collection_address);
        assert!(object::owner(collection) == signer::address_of(creator), 0);
        assert!(collection::count(collection) == option::some(0), 0);
    }

    #[test(creator = @bridge)]
    fun test_create_nft_token(creator: &signer) {
        let collection_name = string::utf8(COLLECTION_NAME);
        // let token_name = string::utf8(b"Mofu #1");
        create_mofu_collection(creator);
        let token_id = 0;
        let token_address = mint_token(creator, token_id);
        let token_object = object::address_to_object<MofuToken>(token_address);
        let token_owner = object::owner(token_object);

        assert!(token_owner == signer::address_of(creator), 0);
        assert!(token::name(token_object) == string::utf8(b"Mofu #1"), 0);
        assert!(token::uri(token_object) == token_uri(METADATA_URI, token_id), 0);
        assert!(
            (token::index(token_object) - 1) == (token_id as u64),
            0
        );
        assert!(object::object_address(&token_object) == token_address, 0);

        token_id = 1;
        let token_address = mint_token(creator, token_id);
        let token_object = object::address_to_object<MofuToken>(token_address);
        assert!(token::name(token_object) == string::utf8(b"Mofu #2"), 0);
        assert!(token::uri(token_object) == token_uri(METADATA_URI, token_id), 0);
        assert!(
            (token::index(token_object) - 1) == (token_id as u64),
            0
        );
        // assert!(token::collection_name(token_object) == string::utf8(COLLECTION_NAME), 0);

        // let collection_name = string::utf8(COLLECTION_NAME);
        let collection_address =
            collection::create_collection_address(
                &signer::address_of(creator), &collection_name
            );

        let collection =
            object::address_to_object<collection::Collection>(collection_address);

        // //
        assert!(collection::count(collection) == option::some(2), 0);
    }

    #[test(creator = @bridge)]
    fun test_create_and_transfer(creator: &signer) {
        create_mofu_collection(creator);
        let token_address = mint_token(creator, 0);

        let token = object::address_to_object<MofuToken>(token_address);

        assert!(object::owner(token) == signer::address_of(creator), 1);
        object::transfer(creator, token, @0x345);
        assert!(object::owner(token) == @0x345, 1);
    }

    #[test(creator = @bridge)]
    fun test_burn_success(creator: &signer) acquires MofuToken {
        create_mofu_collection(creator);
        let token_address = mint_token(creator, 0);
        let token = object::address_to_object<MofuToken>(token_address);

        assert!(object::owner(token) == signer::address_of(creator), 1);
        assert!(token::name(token) == string::utf8(b"Mofu #1"), 1);

        let mofu_token = authorized_borrow(&token, creator);
        move mofu_token;
        let mofu_token = move_from<MofuToken>(object::object_address(&token));
        let MofuToken { burn_ref } = mofu_token;

        token::burn(burn_ref);

        // assert!(object::owner(token) != signer::address_of(creator), 1);
        assert!(exists<MofuToken>(token_address) == false, 1);
    }

    #[test(creator = @bridge, user = @0x345)]
    #[expected_failure(abort_code = 393218)]
    fun test_mint_with_invalid_creator(creator: &signer, user: &signer) {
        create_mofu_collection(creator);
        mint_token(user, 0);
    }

    #[test(creator = @bridge)]
    #[expected_failure(abort_code = 131074)]
    fun test_mint_fails_with_oversize(creator: &signer) {
        create_mofu_collection_for_testing(creator);
        mint_token(creator, 0);
        mint_token(creator, 1);
        mint_token(creator, 2);
        mint_token(creator, 3);
        mint_token(creator, 4);
        mint_token(creator, 5);

    }
}
