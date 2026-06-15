from std.collections import List


struct FixtureMeta(Copyable):
    var fixture_id: String
    var height: Int
    var lane: String
    var required_rules: String

    def __init__(out self):
        self.fixture_id = String("")
        self.height = 0
        self.lane = String("")
        self.required_rules = String("")


def script_fixture_count() -> Int:
    return 45


def _fixture_lane(fixture_id: String) -> String:
    if fixture_id == "scripts.bare_multisig_27840":
        return String("legacy")
    if fixture_id == "scripts.p2wsh_op1_only_31842":
        return String("segwit-v0")
    if fixture_id == "scripts.p2tr_tapscript_numequal_32712":
        return String("taproot")
    if fixture_id == "scripts.p2wsh_cltv_32868":
        return String("segwit-v0")
    if fixture_id == "scripts.p2sh_p2wsh_op1_only_33500":
        return String("segwit-v0")
    if fixture_id == "scripts.p2pkh_sighash_single_38010":
        return String("legacy")
    if fixture_id == "scripts.p2sh_cltv_38191":
        return String("legacy")
    if fixture_id == "scripts.p2tr_scriptpath_44295":
        return String("taproot")
    if fixture_id == "scripts.p2tr_scriptpath_46599":
        return String("taproot")
    if fixture_id == "scripts.p2wsh_size_lessthan_46779":
        return String("segwit-v0")
    if fixture_id == "scripts.p2sh_add_51340":
        return String("legacy")
    if fixture_id == "scripts.p2tr_tapscript_sha256_52024":
        return String("taproot")
    if fixture_id == "scripts.p2tr_tapscript_size_52497":
        return String("taproot")
    if fixture_id == "scripts.p2wsh_2drop_54287":
        return String("segwit-v0")
    if fixture_id == "scripts.p2wsh_ifdup_csv_54297":
        return String("segwit-v0")
    if fixture_id == "scripts.p2wsh_mul_58173":
        return String("segwit-v0")
    if fixture_id == "scripts.p2pkh_61174":
        return String("legacy")
    if fixture_id == "scripts.p2wsh_rot_62754":
        return String("segwit-v0")
    if fixture_id == "scripts.p2sh_3dup_63305":
        return String("legacy")
    if fixture_id == "scripts.p2sh_2dup_63603":
        return String("legacy")
    if fixture_id == "scripts.p2wsh_altstack_66241":
        return String("segwit-v0")
    if fixture_id == "scripts.p2tr_tapscript_hash256_67562":
        return String("taproot")
    if fixture_id == "scripts.p2tr_tapscript_70924":
        return String("taproot")
    if fixture_id == "scripts.p2tr_tapscript_71267":
        return String("taproot")
    if fixture_id == "scripts.p2tr_tapscript_78841":
        return String("taproot")
    if fixture_id == "scripts.p2sh_82112":
        return String("legacy")
    if fixture_id == "scripts.p2tr_tapscript_82856":
        return String("taproot")
    if fixture_id == "scripts.p2sh_82921":
        return String("legacy")
    if fixture_id == "scripts.p2sh_sha1_82921":
        return String("legacy")
    if fixture_id == "scripts.p2tr_tapscript_87214":
        return String("taproot")
    if fixture_id == "scripts.p2tr_tapscript_89632":
        return String("taproot")
    if fixture_id == "scripts.p2wsh_within_98025":
        return String("segwit-v0")
    if fixture_id == "scripts.p2wsh_98631":
        return String("segwit-v0")
    if fixture_id == "scripts.p2wsh_nip_98631":
        return String("segwit-v0")
    if fixture_id == "scripts.p2tr_tapscript_100372":
        return String("taproot")
    if fixture_id == "scripts.p2pkh_107951":
        return String("legacy")
    if fixture_id == "scripts.p2tr_tapscript_108508":
        return String("taproot")
    if fixture_id == "scripts.p2sh_108972":
        return String("legacy")
    if fixture_id == "scripts.p2sh_116040":
        return String("legacy")
    if fixture_id == "scripts.bare_legacy_118555":
        return String("legacy")
    if fixture_id == "scripts.p2tr_tapscript_121035":
        return String("taproot")
    if fixture_id == "scripts.p2tr_tapscript_126975":
        return String("taproot")
    if fixture_id == "scripts.p2sh_abs_132361":
        return String("legacy")
    if fixture_id == "scripts.p2tr_tapscript_133634":
        return String("taproot")
    if fixture_id == "scripts.p2wsh_booland_136369":
        return String("segwit-v0")
    return String("unknown")


def fixture_id_at(index: Int) raises -> String:
    if index == 0:
        return String("scripts.bare_multisig_27840")
    if index == 1:
        return String("scripts.p2wsh_op1_only_31842")
    if index == 2:
        return String("scripts.p2tr_tapscript_numequal_32712")
    if index == 3:
        return String("scripts.p2wsh_cltv_32868")
    if index == 4:
        return String("scripts.p2sh_p2wsh_op1_only_33500")
    if index == 5:
        return String("scripts.p2pkh_sighash_single_38010")
    if index == 6:
        return String("scripts.p2sh_cltv_38191")
    if index == 7:
        return String("scripts.p2tr_scriptpath_44295")
    if index == 8:
        return String("scripts.p2tr_scriptpath_46599")
    if index == 9:
        return String("scripts.p2wsh_size_lessthan_46779")
    if index == 10:
        return String("scripts.p2sh_add_51340")
    if index == 11:
        return String("scripts.p2tr_tapscript_sha256_52024")
    if index == 12:
        return String("scripts.p2tr_tapscript_size_52497")
    if index == 13:
        return String("scripts.p2wsh_2drop_54287")
    if index == 14:
        return String("scripts.p2wsh_ifdup_csv_54297")
    if index == 15:
        return String("scripts.p2wsh_mul_58173")
    if index == 16:
        return String("scripts.p2pkh_61174")
    if index == 17:
        return String("scripts.p2wsh_rot_62754")
    if index == 18:
        return String("scripts.p2sh_3dup_63305")
    if index == 19:
        return String("scripts.p2sh_2dup_63603")
    if index == 20:
        return String("scripts.p2wsh_altstack_66241")
    if index == 21:
        return String("scripts.p2tr_tapscript_hash256_67562")
    if index == 22:
        return String("scripts.p2tr_tapscript_70924")
    if index == 23:
        return String("scripts.p2tr_tapscript_71267")
    if index == 24:
        return String("scripts.p2tr_tapscript_78841")
    if index == 25:
        return String("scripts.p2sh_82112")
    if index == 26:
        return String("scripts.p2tr_tapscript_82856")
    if index == 27:
        return String("scripts.p2sh_82921")
    if index == 28:
        return String("scripts.p2sh_sha1_82921")
    if index == 29:
        return String("scripts.p2tr_tapscript_87214")
    if index == 30:
        return String("scripts.p2tr_tapscript_89632")
    if index == 31:
        return String("scripts.p2wsh_within_98025")
    if index == 32:
        return String("scripts.p2wsh_98631")
    if index == 33:
        return String("scripts.p2wsh_nip_98631")
    if index == 34:
        return String("scripts.p2tr_tapscript_100372")
    if index == 35:
        return String("scripts.p2pkh_107951")
    if index == 36:
        return String("scripts.p2tr_tapscript_108508")
    if index == 37:
        return String("scripts.p2sh_108972")
    if index == 38:
        return String("scripts.p2sh_116040")
    if index == 39:
        return String("scripts.bare_legacy_118555")
    if index == 40:
        return String("scripts.p2tr_tapscript_121035")
    if index == 41:
        return String("scripts.p2tr_tapscript_126975")
    if index == 42:
        return String("scripts.p2sh_abs_132361")
    if index == 43:
        return String("scripts.p2tr_tapscript_133634")
    if index == 44:
        return String("scripts.p2wsh_booland_136369")
    raise Error("script fixture index out of range")


def fixture_meta(fixture_id: String) raises -> FixtureMeta:
    var meta = FixtureMeta()
    if fixture_id == "scripts.bare_multisig_27840":
        meta.fixture_id = String("scripts.bare_multisig_27840")
        meta.height = 27840
        meta.lane = _fixture_lane(fixture_id)
        meta.required_rules = String("multisig")
        return meta^
    if fixture_id == "scripts.p2wsh_op1_only_31842":
        meta.fixture_id = String("scripts.p2wsh_op1_only_31842")
        meta.height = 31842
        meta.lane = _fixture_lane(fixture_id)
        meta.required_rules = String("p2wsh")
        return meta^
    if fixture_id == "scripts.p2tr_tapscript_numequal_32712":
        meta.fixture_id = String("scripts.p2tr_tapscript_numequal_32712")
        meta.height = 32712
        meta.lane = _fixture_lane(fixture_id)
        meta.required_rules = String("op_numequal,p2tr,tapscript")
        return meta^
    if fixture_id == "scripts.p2wsh_cltv_32868":
        meta.fixture_id = String("scripts.p2wsh_cltv_32868")
        meta.height = 32868
        meta.lane = _fixture_lane(fixture_id)
        meta.required_rules = String("cltv,op_checklocktimeverify,p2wsh")
        return meta^
    if fixture_id == "scripts.p2sh_p2wsh_op1_only_33500":
        meta.fixture_id = String("scripts.p2sh_p2wsh_op1_only_33500")
        meta.height = 33500
        meta.lane = _fixture_lane(fixture_id)
        meta.required_rules = String("p2sh,p2wsh")
        return meta^
    if fixture_id == "scripts.p2pkh_sighash_single_38010":
        meta.fixture_id = String("scripts.p2pkh_sighash_single_38010")
        meta.height = 38010
        meta.lane = _fixture_lane(fixture_id)
        meta.required_rules = String("p2pkh,sighash")
        return meta^
    if fixture_id == "scripts.p2sh_cltv_38191":
        meta.fixture_id = String("scripts.p2sh_cltv_38191")
        meta.height = 38191
        meta.lane = _fixture_lane(fixture_id)
        meta.required_rules = String("cltv,op_checklocktimeverify,p2sh")
        return meta^
    if fixture_id == "scripts.p2tr_scriptpath_44295":
        meta.fixture_id = String("scripts.p2tr_scriptpath_44295")
        meta.height = 44295
        meta.lane = _fixture_lane(fixture_id)
        meta.required_rules = String("op_0,op_checksigverify,op_endif,op_if,op_nip,p2tr")
        return meta^
    if fixture_id == "scripts.p2tr_scriptpath_46599":
        meta.fixture_id = String("scripts.p2tr_scriptpath_46599")
        meta.height = 46599
        meta.lane = _fixture_lane(fixture_id)
        meta.required_rules = String("op_0,op_checksigverify,op_endif,op_if,op_nip,p2tr")
        return meta^
    if fixture_id == "scripts.p2wsh_size_lessthan_46779":
        meta.fixture_id = String("scripts.p2wsh_size_lessthan_46779")
        meta.height = 46779
        meta.lane = _fixture_lane(fixture_id)
        meta.required_rules = String("p2wsh")
        return meta^
    if fixture_id == "scripts.p2sh_add_51340":
        meta.fixture_id = String("scripts.p2sh_add_51340")
        meta.height = 51340
        meta.lane = _fixture_lane(fixture_id)
        meta.required_rules = String("op_3,op_add,op_equal,p2sh")
        return meta^
    if fixture_id == "scripts.p2tr_tapscript_sha256_52024":
        meta.fixture_id = String("scripts.p2tr_tapscript_sha256_52024")
        meta.height = 52024
        meta.lane = _fixture_lane(fixture_id)
        meta.required_rules = String("p2tr,tapscript")
        return meta^
    if fixture_id == "scripts.p2tr_tapscript_size_52497":
        meta.fixture_id = String("scripts.p2tr_tapscript_size_52497")
        meta.height = 52497
        meta.lane = _fixture_lane(fixture_id)
        meta.required_rules = String("p2tr,tapscript")
        return meta^
    if fixture_id == "scripts.p2wsh_2drop_54287":
        meta.fixture_id = String("scripts.p2wsh_2drop_54287")
        meta.height = 54287
        meta.lane = _fixture_lane(fixture_id)
        meta.required_rules = String("op_2drop,op_equal,op_hash160,p2wsh")
        return meta^
    if fixture_id == "scripts.p2wsh_ifdup_csv_54297":
        meta.fixture_id = String("scripts.p2wsh_ifdup_csv_54297")
        meta.height = 54297
        meta.lane = _fixture_lane(fixture_id)
        meta.required_rules = String("csv,op_checkmultisig,op_checksequenceverify,op_checksig,op_else,op_endif,op_if,op_ifdup,op_notif,op_verify,p2wsh")
        return meta^
    if fixture_id == "scripts.p2wsh_mul_58173":
        meta.fixture_id = String("scripts.p2wsh_mul_58173")
        meta.height = 58173
        meta.lane = _fixture_lane(fixture_id)
        meta.required_rules = String("op_0notequal,op_add,op_checkmultisig,op_checksequenceverify,op_checksigverify,op_endif,op_equal,op_if,op_size,op_swap,p2wsh")
        return meta^
    if fixture_id == "scripts.p2pkh_61174":
        meta.fixture_id = String("scripts.p2pkh_61174")
        meta.height = 61174
        meta.lane = _fixture_lane(fixture_id)
        meta.required_rules = String("p2pkh")
        return meta^
    if fixture_id == "scripts.p2wsh_rot_62754":
        meta.fixture_id = String("scripts.p2wsh_rot_62754")
        meta.height = 62754
        meta.lane = _fixture_lane(fixture_id)
        meta.required_rules = String("op_checksequenceverify,op_checksig,op_drop,op_else,op_endif,op_equal,op_equalverify,op_hash160,op_if,op_rot,op_size,op_swap,p2wsh")
        return meta^
    if fixture_id == "scripts.p2sh_3dup_63305":
        meta.fixture_id = String("scripts.p2sh_3dup_63305")
        meta.height = 63305
        meta.lane = _fixture_lane(fixture_id)
        meta.required_rules = String("op_3dup,op_add,op_equalverify,p2sh")
        return meta^
    if fixture_id == "scripts.p2sh_2dup_63603":
        meta.fixture_id = String("scripts.p2sh_2dup_63603")
        meta.height = 63603
        meta.lane = _fixture_lane(fixture_id)
        meta.required_rules = String("op_2dup,op_add,op_equal,op_equalverify,op_sub,p2sh")
        return meta^
    if fixture_id == "scripts.p2wsh_altstack_66241":
        meta.fixture_id = String("scripts.p2wsh_altstack_66241")
        meta.height = 66241
        meta.lane = _fixture_lane(fixture_id)
        meta.required_rules = String("op_0notequal,op_add,op_checkmultisig,op_checksequenceverify,op_checksigverify,op_endif,op_equal,op_fromaltstack,op_if,op_size,op_swap,op_toaltstack,p2wsh")
        return meta^
    if fixture_id == "scripts.p2tr_tapscript_hash256_67562":
        meta.fixture_id = String("scripts.p2tr_tapscript_hash256_67562")
        meta.height = 67562
        meta.lane = _fixture_lane(fixture_id)
        meta.required_rules = String("op_hash256,p2tr,p2tr script-path,tapscript")
        return meta^
    if fixture_id == "scripts.p2tr_tapscript_70924":
        meta.fixture_id = String("scripts.p2tr_tapscript_70924")
        meta.height = 70924
        meta.lane = _fixture_lane(fixture_id)
        meta.required_rules = String("op_min,op_pick,op_tuck,p2tr,p2tr script-path,tapscript")
        return meta^
    if fixture_id == "scripts.p2tr_tapscript_71267":
        meta.fixture_id = String("scripts.p2tr_tapscript_71267")
        meta.height = 71267
        meta.lane = _fixture_lane(fixture_id)
        meta.required_rules = String("op_2swap,op_3dup,op_depth,op_numequalverify,op_numnotequal,op_roll,op_rot,p2tr,p2tr script-path,tapscript")
        return meta^
    if fixture_id == "scripts.p2tr_tapscript_78841":
        meta.fixture_id = String("scripts.p2tr_tapscript_78841")
        meta.height = 78841
        meta.lane = _fixture_lane(fixture_id)
        meta.required_rules = String("op_max,p2tr,p2tr script-path,tapscript")
        return meta^
    if fixture_id == "scripts.p2sh_82112":
        meta.fixture_id = String("scripts.p2sh_82112")
        meta.height = 82112
        meta.lane = _fixture_lane(fixture_id)
        meta.required_rules = String("op_nop,p2sh")
        return meta^
    if fixture_id == "scripts.p2tr_tapscript_82856":
        meta.fixture_id = String("scripts.p2tr_tapscript_82856")
        meta.height = 82856
        meta.lane = _fixture_lane(fixture_id)
        meta.required_rules = String("op_sha1,p2tr,p2tr script-path,tapscript")
        return meta^
    if fixture_id == "scripts.p2sh_82921":
        meta.fixture_id = String("scripts.p2sh_82921")
        meta.height = 82921
        meta.lane = _fixture_lane(fixture_id)
        meta.required_rules = String("op_not,op_sha1,p2sh")
        return meta^
    if fixture_id == "scripts.p2sh_sha1_82921":
        meta.fixture_id = String("scripts.p2sh_sha1_82921")
        meta.height = 82921
        meta.lane = _fixture_lane(fixture_id)
        meta.required_rules = String("op_not,op_sha1,p2sh")
        return meta^
    if fixture_id == "scripts.p2tr_tapscript_87214":
        meta.fixture_id = String("scripts.p2tr_tapscript_87214")
        meta.height = 87214
        meta.lane = _fixture_lane(fixture_id)
        meta.required_rules = String("op_ifdup,p2tr,p2tr script-path,tapscript")
        return meta^
    if fixture_id == "scripts.p2tr_tapscript_89632":
        meta.fixture_id = String("scripts.p2tr_tapscript_89632")
        meta.height = 89632
        meta.lane = _fixture_lane(fixture_id)
        meta.required_rules = String("op_checklocktimeverify,op_checksequenceverify,p2tr,p2tr script-path,tapscript")
        return meta^
    if fixture_id == "scripts.p2wsh_within_98025":
        meta.fixture_id = String("scripts.p2wsh_within_98025")
        meta.height = 98025
        meta.lane = _fixture_lane(fixture_id)
        meta.required_rules = String("op_checksig,op_size,op_verify,op_within,p2wsh")
        return meta^
    if fixture_id == "scripts.p2wsh_98631":
        meta.fixture_id = String("scripts.p2wsh_98631")
        meta.height = 98631
        meta.lane = _fixture_lane(fixture_id)
        meta.required_rules = String("op_2dup,op_checksig,op_checksigverify,op_drop,op_nip,op_swap,p2wsh")
        return meta^
    if fixture_id == "scripts.p2wsh_nip_98631":
        meta.fixture_id = String("scripts.p2wsh_nip_98631")
        meta.height = 98631
        meta.lane = _fixture_lane(fixture_id)
        meta.required_rules = String("op_2dup,op_checksig,op_checksigverify,op_drop,op_nip,op_swap,p2wsh")
        return meta^
    if fixture_id == "scripts.p2tr_tapscript_100372":
        meta.fixture_id = String("scripts.p2tr_tapscript_100372")
        meta.height = 100372
        meta.lane = _fixture_lane(fixture_id)
        meta.required_rules = String("p2tr,p2tr script-path,tapscript")
        return meta^
    if fixture_id == "scripts.p2pkh_107951":
        meta.fixture_id = String("scripts.p2pkh_107951")
        meta.height = 107951
        meta.lane = _fixture_lane(fixture_id)
        meta.required_rules = String("op_1,p2pkh")
        return meta^
    if fixture_id == "scripts.p2tr_tapscript_108508":
        meta.fixture_id = String("scripts.p2tr_tapscript_108508")
        meta.height = 108508
        meta.lane = _fixture_lane(fixture_id)
        meta.required_rules = String("op_1sub,op_depth,op_if,p2tr,p2tr script-path,tapscript")
        return meta^
    if fixture_id == "scripts.p2sh_108972":
        meta.fixture_id = String("scripts.p2sh_108972")
        meta.height = 108972
        meta.lane = _fixture_lane(fixture_id)
        meta.required_rules = String("op_2over,op_2swap,op_depth,op_pick,p2sh")
        return meta^
    if fixture_id == "scripts.p2sh_116040":
        meta.fixture_id = String("scripts.p2sh_116040")
        meta.height = 116040
        meta.lane = _fixture_lane(fixture_id)
        meta.required_rules = String("op_ripemd160,p2sh")
        return meta^
    if fixture_id == "scripts.bare_legacy_118555":
        meta.fixture_id = String("scripts.bare_legacy_118555")
        meta.height = 118555
        meta.lane = _fixture_lane(fixture_id)
        meta.required_rules = String("bare_legacy")
        return meta^
    if fixture_id == "scripts.p2tr_tapscript_121035":
        meta.fixture_id = String("scripts.p2tr_tapscript_121035")
        meta.height = 121035
        meta.lane = _fixture_lane(fixture_id)
        meta.required_rules = String("op_boolor,p2tr,p2tr script-path,tapscript")
        return meta^
    if fixture_id == "scripts.p2tr_tapscript_126975":
        meta.fixture_id = String("scripts.p2tr_tapscript_126975")
        meta.height = 126975
        meta.lane = _fixture_lane(fixture_id)
        meta.required_rules = String("op_2over,op_over,p2tr,p2tr script-path,tapscript")
        return meta^
    if fixture_id == "scripts.p2sh_abs_132361":
        meta.fixture_id = String("scripts.p2sh_abs_132361")
        meta.height = 132361
        meta.lane = _fixture_lane(fixture_id)
        meta.required_rules = String("op_abs,p2sh")
        return meta^
    if fixture_id == "scripts.p2tr_tapscript_133634":
        meta.fixture_id = String("scripts.p2tr_tapscript_133634")
        meta.height = 133634
        meta.lane = _fixture_lane(fixture_id)
        meta.required_rules = String("p2tr,p2tr script-path,tapscript")
        return meta^
    if fixture_id == "scripts.p2wsh_booland_136369":
        meta.fixture_id = String("scripts.p2wsh_booland_136369")
        meta.height = 136369
        meta.lane = _fixture_lane(fixture_id)
        meta.required_rules = String("op_booland,op_checksig,op_equal,op_equalverify,op_ripemd160,op_size,op_swap,p2wsh")
        return meta^
    raise Error("unknown script fixture id")


def fixture_in_set(fixture_id: String, fixture_set: String) raises -> Bool:
    if fixture_set == "all":
        return True
    var lane = _fixture_lane(fixture_id)
    if fixture_set == "legacy":
        return lane == "legacy"
    if fixture_set == "segwit-v0":
        return lane == "segwit-v0"
    if fixture_set == "taproot":
        return lane == "taproot"
    if fixture_set == "non-taproot":
        return lane != "taproot"
    raise Error("unknown script fixture set")


def selected_fixture_ids(fixture_id: String, fixture_set: String) raises -> List[String]:
    var selected = List[String]()
    if fixture_id != "":
        _ = fixture_meta(fixture_id)
        selected.append(String(fixture_id))
        return selected^
    for i in range(script_fixture_count()):
        var current = fixture_id_at(i)
        var current_for_match = String(current)
        if fixture_in_set(current_for_match, fixture_set):
            selected.append(fixture_id_at(i))
    return selected^
