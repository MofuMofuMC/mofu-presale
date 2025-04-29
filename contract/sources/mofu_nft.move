module bridge::mofu_nft {
    use std::error;
    use std::string::{Self, String};
    use std::option::{Self};
    use aptos_framework::object::{Self, Object};
    use aptos_token_objects::collection::{Self};
    use aptos_token_objects::token::{Self};
    use aptos_token_objects::royalty::{Self};
    use std::signer;
    use aptos_std::string_utils;

    friend bridge::bridge;

    // ======== Constants ========

    const COLLECTION_NAME: vector<u8> = b"Mofu Mofu Music Caravan";
    const METADATA_URI: vector<u8> = b"https://bafybeiekgc2nuuwsr3vp5rvepp3kidytatzydrtjztvhpkyjweiknseg5u.ipfs.nftstorage.link/";
    const COLLECTION_MAX_SUPPLY: u64 = 500;
    const COLLECTION_DESCRIPTION: vector<u8> = b"Welcome to Mofu World, a place where the spirit of free music faces a challenge unlike any other. Introducing the Traveler's Radio: a symbol of defiance, a badge of honour for the courageous few ready to stand up for the power of music. This exclusive radio grants access to a secret frequency, a hidden channel where the pure, unadulterated music of the soul flows freely.";
    const COLLECTION_URI: vector<u8> = b"https://mmmc.toho.co.jp";

    // ======== Errors ========

    const ETOKEN_DOES_NOT_EXIST: u64 = 1;
    const ENOT_CREATOR: u64 = 2;
    const EMISMATCH_TOKEN_ID: u64 = 3;

    // ========= Structs =========

    #[resource_group_member(group = aptos_framework::object::ObjectGroup)]
    /// A struct holding items to control properties of a token
    struct MofuToken has key {
        /// Used to mutate the token.
        // mutator_ref: token::MutatorRef,
        /// Used to burn.
        burn_ref: token::BurnRef
    }

    // ======== Public Package Functions ========

    /// Mint a new Mofu NFT token with a unique token_id.
    /// Only callable by the collection creator.
    /// Returns the address of the newly minted token.
    public(friend) fun mint_token(creator: &signer, token_id: u256): address {
        let metadata_uri = token_uri(METADATA_URI, token_id);

        let constructor_ref =
            token::create_named_token(
                creator,
                string::utf8(COLLECTION_NAME),
                string::utf8(COLLECTION_DESCRIPTION), // Description
                token_name_with_id(token_id), // Name
                option::none(), // No royalty
                metadata_uri
            );
        let burn_ref = token::generate_burn_ref(&constructor_ref);
        let object_signer = object::generate_signer(&constructor_ref);
        // let transfer_ref = object::generate_transfer_ref(&constructor_ref);

        let mofu_token = MofuToken { burn_ref };

        move_to(&object_signer, mofu_token);

        let token_object =
            object::object_from_constructor_ref<MofuToken>(&constructor_ref);

        assert!(
            (token::index(token_object) - 1) == (token_id as u64),
            error::invalid_state(EMISMATCH_TOKEN_ID)
        );
        let token_address = object::object_address(&token_object);

        token_address
    }

    public(friend) inline fun create_mofu_collection(creator: &signer) {
        let description = string::utf8(COLLECTION_DESCRIPTION);
        let name = string::utf8(COLLECTION_NAME);
        let uri = string::utf8(COLLECTION_URI);
        let royalty = royalty::create(
            5, // 5%
            100,
            signer::address_of(creator)
        );

        collection::create_fixed_collection(
            creator,
            description,
            COLLECTION_MAX_SUPPLY,
            name,
            option::some(royalty),
            uri
        );
    }

    /// Generate the token name with its ID, e.g., "Mofu Genesis #1"
    inline fun token_name_with_id(token_id: u256): String {
        let name = string::utf8(b"Mofu Genesis #");
        string::append(&mut name, string_utils::to_string(&token_id));
        name
    }

    /// Generate the metadata URI for a token, e.g., "<base_uri>1.json"
    inline fun token_uri(base_uri: vector<u8>, token_id: u256): String {
        let uri = string::utf8(base_uri);
        string::append(&mut uri, string_utils::to_string(&token_id));
        string::append(&mut uri, string::utf8(b".json"));
        uri
    }

    /// Borrow the MofuToken resource for a given token, ensuring the caller is the creator.
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

    // ======= Views ========

    #[view]
    /// Get the address of the collection owner.
    public fun collection_owner(): address {
        object::create_object_address(
            &@bridge,
            collection::create_collection_seed(&string::utf8(COLLECTION_NAME))
        )
    }

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
        assert!(token::name(token_object) == string::utf8(b"Mofu Genesis #0"), 0);
        assert!(token::uri(token_object) == token_uri(METADATA_URI, token_id), 0);
        assert!(
            (token::index(token_object) - 1) == (token_id as u64),
            0
        );
        assert!(object::object_address(&token_object) == token_address, 0);

        token_id = 1;
        let token_address = mint_token(creator, token_id);
        let token_object = object::address_to_object<MofuToken>(token_address);
        assert!(token::name(token_object) == string::utf8(b"Mofu Genesis #1"), 0);
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

    // #[test_only]
    // use aptos_framework::aggregator_v2::{Self};

    #[test(creator = @bridge)]
    fun test_token_ids(creator: &signer) {
        use std::debug;
        create_mofu_collection(creator);
        let token_id = 0;
        let token_address = mint_token(creator, token_id);
        let token_object =
            object::address_to_object<token::TokenIdentifiers>(token_address);

        // debug::print(&token::index(token_object));
        let token_name = token::name(token_object);
        debug::print(&token_name);
        // assert!(token::index(token_object) == (token_id as u64), 0);
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
        assert!(token::name(token) == string::utf8(b"Mofu Genesis #0"), 1);

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
