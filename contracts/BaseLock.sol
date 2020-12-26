// SPDX-License-Identifier: LGPL-3.0-or-later
pragma solidity ^0.7.1;
import { SafeMath } from "@openzeppelin/contracts/math/SafeMath.sol";
import { ABDKMath64x64 } from "abdk-libraries-solidity/ABDKMath64x64.sol";
import { ERC1155WithMappedAddressesAndTotals } from "./ERC1155/ERC1155WithMappedAddressesAndTotals.sol";
import { IERC1155TokenReceiver } from "./ERC1155/IERC1155TokenReceiver.sol";
import { IERC1155 } from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";

/// @title Bidding on Ethereum addresses
/// @author Victor Porton
/// @notice Not audited, not enough tested.
/// This allows anyone claim 1000 conditional tokens in order for him to transfer money from the future.
/// See `docs/future-money.rst`.
///
/// We have three kinds of ERC-1155 token ID
/// - a combination of market ID, collateral address, and customer address (conditional tokens)
/// - a combination of TOKEN_STAKED and collateral address (bequested collateral tokens)
/// - a combination of TOKEN_SUMMARY and collateral address (bequested + bequested collateral tokens)
///
/// In functions of this contact `condition` is always a customer's original address.
abstract contract BaseLock is ERC1155WithMappedAddressesAndTotals, IERC1155TokenReceiver {
    using ABDKMath64x64 for int128;
    using SafeMath for uint256;

    enum TokenKind { TOKEN_CONDITIONAL, TOKEN_DONATED, TOKEN_BEQUESTED }

    event OracleCreated(address oracleOwner, uint64 oracleId);

    event OracleOwnerChanged(address oracleOwner, uint64 oracleId);

    event DonateCollateral(
        IERC1155 collateralContractAddress,
        uint256 collateralTokenId,
        address sender,
        uint256 amount,
        address to,
        bytes data
    );

    event BequestCollateral(
        IERC1155 collateralContractAddress,
        uint256 collateralTokenId,
        address sender,
        uint256 amount,
        address to,
        bytes data
    );

    event TakeBackCollateral(
        IERC1155 collateralContractAddress,
        uint256 collateralTokenId,
        address sender,
        uint256 amount,
        address to
    );

    event ConvertBequestedToDonated(
        IERC1155 collateralContractAddress,
        uint256 collateralTokenId,
        address sender,
        uint256 amount,
        address to,
        bytes data
    );

    event OracleFinished(address indexed oracleOwner);

    event RedeemCalculated(
        address user,
        IERC1155 collateralContractAddress,
        uint256 collateralTokenId,
        uint64 indexed oracleId,
        address condition,
        uint payout
    );

    event CollateralWithdrawn(
        IERC1155 contractAdrress,
        uint256 collateralTokenId,
        uint64 oracleId,
        address user,
        uint256 amount
    );
    
    uint64 private maxId;

    // Mapping from oracleId to oracle owner.
    mapping(uint64 => address) private oracleOwnersMap;
    // Mapping (oracleId => time) the max time for first withdrawal.
    mapping(uint64 => uint) private gracePeriodEnds;
    // The user lost the right to transfer conditional tokens: (user => (conditionalToken => bool)).
    mapping(address => mapping(uint256 => bool)) private userUsedRedeemMap;
    // Mapping (token => (user => amount)) used to calculate withdrawal of collateral amounts.
    mapping(uint256 => mapping(address => uint256)) private lastCollateralBalanceFirstRoundMap; // TODO: Would getter be useful?
    // Mapping (token => (user => amount)) used to calculate withdrawal of collateral amounts.
    mapping(uint256 => mapping(address => uint256)) private lastCollateralBalanceSecondRoundMap; // TODO: Would getter be useful?
    /// Times of bequest of all funds from address (zero is no bequest).
    mapping(address => uint) public bequestTimes;
    /// Mapping (oracleId => user withdrew in first round) (see `docs/Calculations.md`).
    mapping(uint64 => uint256) public usersWithdrewInFirstRound;

    constructor(string memory uri_) ERC1155WithMappedAddressesAndTotals(uri_) {
        _registerInterface(
            BaseLock(0).onERC1155Received.selector ^
            BaseLock(0).onERC1155BatchReceived.selector
        );
    }

    /// Create a new oracle
    function createOracle() external returns (uint64) {
        uint64 oracleId = maxId++;
        oracleOwnersMap[oracleId] = msg.sender;
        emit OracleCreated(msg.sender, oracleId);
        emit OracleOwnerChanged(msg.sender, oracleId);
        return oracleId;
    }

    function changeOracleOwner(address newOracleOwner, uint64 oracleId) public _isOracle(oracleId) {
        oracleOwnersMap[oracleId] = newOracleOwner;
        emit OracleOwnerChanged(newOracleOwner, oracleId);
    }

    function updateGracePeriodEnds(uint64 oracleId, uint time) public _isOracle(oracleId) {
        gracePeriodEnds[oracleId] = time;
    }

    /// Bequest either by calling this function and also approving transfers by this contract
    /// or by `bequestCollateral()`.
    /// Zero means disallowed.
    function setBequestTime(uint _time) public {
        bequestTimes[msg.sender] = _time;
    }

    /// Donate funds in a ERC1155 token.
    /// First need to approve the contract to spend the token.
    /// Not recommended to donate after any oracle has finished, because funds may be (partially) lost.
    /// Bequestor's funds after the bequest time can be donated by anyone.
    function donate(
        IERC1155 collateralContractAddress,
        uint256 collateralTokenId,
        uint64 oracleId,
        uint256 amount,
        address from,
        address to,
        bytes calldata data) external
    {
        uint donatedCollateralTokenId = _collateralDonatedTokenId(collateralContractAddress, collateralTokenId, oracleId);
        _mint(to, donatedCollateralTokenId, amount, data);
        emit DonateCollateral(collateralContractAddress, collateralTokenId, from, amount, to, data);
        collateralContractAddress.safeTransferFrom(from, address(this), collateralTokenId, amount, data); // last against reentrancy attack
    }

    /// Bequest funds in a ERC1155 token.
    /// First need to approve the contract to spend the token.
    /// The bequest is lost if either: the prediction period ends or the bequestor loses his private key (e.g. dies).
    /// Not recommended to bequest after the oracle has finished, because funds may be (partially) lost (you could not unbequest).
    function bequestCollateral(
        IERC1155 collateralContractAddress,
        uint256 collateralTokenId,
        uint64 oracleId,
        uint256 amount,
        address to,
        bytes calldata data) external
    {
        uint bequestedCollateralTokenId = _collateralBequestedTokenId(collateralContractAddress, collateralTokenId, oracleId);
        _mint(to, bequestedCollateralTokenId, amount, data);
        emit BequestCollateral(collateralContractAddress, collateralTokenId, msg.sender, amount, to, data);
        collateralContractAddress.safeTransferFrom(msg.sender, address(this), collateralTokenId, amount, data); // last against reentrancy attack
    }

    function takeBequestBack(
        IERC1155 collateralContractAddress,
        uint256 collateralTokenId,
        uint64 oracleId,
        uint256 amount,
        address to,
        bytes calldata data) external _canTakeBequest(msg.sender)
    {
        uint bequestedCollateralTokenId = _collateralBequestedTokenId(collateralContractAddress, collateralTokenId, oracleId);
        collateralContractAddress.safeTransferFrom(address(this), to, bequestedCollateralTokenId, amount, data);
        emit TakeBackCollateral(collateralContractAddress, collateralTokenId, msg.sender, amount, to);
    }

    /// Donate funds from your bequest.
    function convertBequestedToDonated(
        IERC1155 collateralContractAddress,
        uint256 collateralTokenId,
        uint64 oracleId,
        uint256 amount,
        address to,
        bytes calldata data) external
    {
        // Subtract from bequested:
        uint bequestedCollateralTokenId = _collateralBequestedTokenId(collateralContractAddress, collateralTokenId, oracleId);
        _burn(msg.sender, bequestedCollateralTokenId, amount);
        // Add to donated:
        uint donatedCollateralTokenId = _collateralDonatedTokenId(collateralContractAddress, collateralTokenId, oracleId);
        _mint(to, donatedCollateralTokenId, amount, data);
        emit ConvertBequestedToDonated(collateralContractAddress, collateralTokenId, msg.sender, amount, to, data);
    }

    function collateralOwingBase(
        IERC1155 collateralContractAddress,
        uint256 collateralTokenId,
        uint64 oracleId,
        address condition,
        address user,
        bool inFirstRound
    )
        private view returns (uint donatedCollateralTokenId, uint bequestedCollateralTokenId, uint256 donated, uint256 bequested)
    {
        uint256 conditionalToken = _conditionalTokenId(oracleId, condition);
        uint256 conditionalBalance = balanceOf(user, conditionalToken);
        uint256 totalConditionalBalance =
            inFirstRound ? totalBalanceOf(conditionalToken) : usersWithdrewInFirstRound[oracleId];
        donatedCollateralTokenId = _collateralDonatedTokenId(collateralContractAddress, collateralTokenId, oracleId);
        bequestedCollateralTokenId = _collateralBequestedTokenId(collateralContractAddress, collateralTokenId, oracleId);
        // Rounded to below for no out-of-funds:
        int128 oracleShare = ABDKMath64x64.divu(conditionalBalance, totalConditionalBalance);
        uint256 _newDividendsDonated =
            totalBalanceOf(donatedCollateralTokenId) -
            (inFirstRound
                ? lastCollateralBalanceFirstRoundMap[donatedCollateralTokenId][user] 
                : lastCollateralBalanceSecondRoundMap[donatedCollateralTokenId][user]);
        uint256 _newDividendsBequested =
            totalBalanceOf(bequestedCollateralTokenId) -
            (inFirstRound
                ? lastCollateralBalanceFirstRoundMap[bequestedCollateralTokenId][user]
                : lastCollateralBalanceSecondRoundMap[bequestedCollateralTokenId][user]);
        int128 multiplier = _calcMultiplier(oracleId, condition, oracleShare);
        donated = multiplier.mulu(_newDividendsDonated);
        bequested = multiplier.mulu(_newDividendsBequested);
    }
 
    function collateralOwing(
        IERC1155 collateralContractAddress,
        uint256 collateralTokenId,
        uint64 oracleId,
        address condition,
        address user
    ) external view returns(uint256) {
        bool inFirstRound = _inFirstRound(oracleId);
        (,, uint256 donated, uint256 bequested) =
            collateralOwingBase(collateralContractAddress, collateralTokenId, oracleId, condition, user, inFirstRound);
        return donated + bequested;
    }

    function _inFirstRound(uint64 oracleId) internal view returns (bool) {
        return block.timestamp < gracePeriodEnds[oracleId];
    }

    /// Transfer to `msg.sender` the collateral ERC-20 token (we can't transfer to somebody other, because anybody can transfer).
    /// accordingly to the score of `condition` by the oracle.
    /// After this function is called, it becomes impossible to transfer the corresponding conditional token of `msg.sender`
    /// (to prevent its repeated withdraw).
    function withdrawCollateral(IERC1155 collateralContractAddress, uint256 collateralTokenId, uint64 oracleId, address condition, bytes calldata data) external {
        require(isOracleFinished(oracleId), "too early"); // to prevent the denominator or the numerators change meantime
        bool inFirstRound = _inFirstRound(oracleId);
        uint256 conditionalTokenId = _conditionalTokenId(oracleId, condition);
        userUsedRedeemMap[msg.sender][conditionalTokenId] = true;
        // _burn(msg.sender, conditionalTokenId, conditionalBalance); // Burning it would break using the same token for multiple markets.
        (uint donatedCollateralTokenId, uint bequestedCollateralTokenId, uint256 _owingDonated, uint256 _owingBequested) =
            collateralOwingBase(collateralContractAddress, collateralTokenId, oracleId, condition, msg.sender, inFirstRound);

        // Against rounding errors. Not necessary because of rounding down.
        // if(_owing > balanceOf(address(this), collateralTokenId)) _owing = balanceOf(address(this), collateralTokenId);

        if (_owingDonated != 0) {
            uint256 newTotal = totalBalanceOf(donatedCollateralTokenId);
            if (inFirstRound) {
                lastCollateralBalanceFirstRoundMap[donatedCollateralTokenId][msg.sender] = newTotal;
            } else {
                lastCollateralBalanceSecondRoundMap[donatedCollateralTokenId][msg.sender] = newTotal;
            }
        }
        if (_owingBequested != 0) {
            uint256 newTotal = totalBalanceOf(bequestedCollateralTokenId);
            if (inFirstRound) {
                lastCollateralBalanceFirstRoundMap[bequestedCollateralTokenId][msg.sender] = newTotal;
            } else {
                lastCollateralBalanceSecondRoundMap[bequestedCollateralTokenId][msg.sender] = newTotal;
            }
        }
        uint256 _amount = _owingDonated + _owingBequested;
        if (!inFirstRound) {
            usersWithdrewInFirstRound[oracleId] = usersWithdrewInFirstRound[oracleId].add(_amount);
        }
        // Last to prevent reentrancy attack:
        collateralContractAddress.safeTransferFrom(address(this), msg.sender, collateralTokenId, _amount, data);
    }

    /// Disallow transfers of conditional tokens after redeem to prevent "gathering" them before redeeming each oracle.
    function safeTransferFrom(
        address from,
        address to,
        uint256 id,
        uint256 value,
        bytes calldata data
    )
        public override
    {
        _checkTransferAllowed(id, from);
        _baseSafeTransferFrom(from, to, id, value, data);
    }

    /// Disallow transfers of conditional tokens after redeem to prevent "gathering" them before redeeming each oracle.
    function safeBatchTransferFrom(
        address from,
        address to,
        uint256[] calldata ids,
        uint256[] calldata values,
        bytes calldata data
    )
        public override
    {
        for(uint i = 0; i < ids.length; ++i) {
            _checkTransferAllowed(ids[i], from);
        }
        _baseSafeBatchTransferFrom(from, to, ids, values, data);
    }

    /// Don't send funds to us directy (they will be lost!), use smart contract API.
    function onERC1155Received(address, address, uint256, uint256, bytes calldata) public pure override returns(bytes4) {
        return this.onERC1155Received.selector; // to accept transfers
    }

    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata) public pure override returns(bytes4) {
        return bytes4(0); // We should never receive batch transfers.
    }

    // Getters //

    function summaryCollateral(address user, uint256 donatedCollateralTokenId, uint256 bequestedCollateralTokenId) public view returns (uint256) {
        return balanceOf(user, donatedCollateralTokenId) + balanceOf(user, bequestedCollateralTokenId);
    }

    function summaryCollateralTotal(uint256 donatedCollateralTokenId, uint256 bequestedCollateralTokenId) public view returns (uint256) {
        return totalBalanceOf(donatedCollateralTokenId) + totalBalanceOf(bequestedCollateralTokenId);
    }

    function oracleOwner(uint64 oracleId) public view returns (address) {
        return oracleOwnersMap[oracleId];
    }

    function isOracleFinished(uint64 /*oracleId*/) public virtual view returns (bool) {
        return true;
    }

    function isConditionalLocked(address condition, uint256 conditionalTokenId) public view returns (bool) {
        return userUsedRedeemMap[condition][conditionalTokenId];
    }

    function gracePeriodEnd(uint64 oracleId) public view returns (uint) {
        return gracePeriodEnds[oracleId];
    }

    // Virtual functions //

    function _mintToCustomer(uint256 conditionalTokenId, uint256 amount, bytes calldata data) internal virtual {
        _mint(msg.sender, conditionalTokenId, amount, data);
    }

    function _calcRewardShare(uint64 oracleId, address condition) internal virtual view returns (int128);

    function _calcMultiplier(uint64 oracleId, address condition, int128 oracleShare) internal virtual view returns (int128) {
        int128 rewardShare = _calcRewardShare(oracleId, condition);
        return oracleShare.mul(rewardShare);
    }

    // Internal //

    function _conditionalTokenId(uint64 oracleId, address condition) internal pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(uint8(TokenKind.TOKEN_CONDITIONAL), oracleId, condition)));
    }

    function _collateralDonatedTokenId(IERC1155 collateralContractAddress, uint256 collateralTokenId, uint64 oracleId) internal pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(uint8(TokenKind.TOKEN_DONATED), collateralContractAddress, collateralTokenId, oracleId)));
    }

    function _collateralBequestedTokenId(IERC1155 collateralContractAddress, uint256 collateralTokenId, uint64 oracleId) internal pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(uint8(TokenKind.TOKEN_BEQUESTED), collateralContractAddress, collateralTokenId, oracleId)));
    }

    function _checkTransferAllowed(uint256 id, address from) internal view {
        require(!userUsedRedeemMap[originalAddress(from)][id], "You can't trade conditional tokens after redeem.");
    }

    function _baseSafeTransferFrom(
        address from,
        address to,
        uint256 id,
        uint256 value,
        bytes memory data
    )
        private
    {
        require(to != address(0), "ERC1155: target address must be non-zero");
        require(
            from == msg.sender || _operatorApprovals[from][msg.sender] == true,
            "ERC1155: need operator approval for 3rd party transfers."
        );

        _doTransfer(id, from, to, value);

        emit TransferSingle(msg.sender, from, to, id, value);

        _doSafeTransferAcceptanceCheck(msg.sender, from, to, id, value, data);
    }

    function _baseSafeBatchTransferFrom(
        address from,
        address to,
        uint256[] memory ids,
        uint256[] memory values,
        bytes memory data
    )
        private
    {
        require(ids.length == values.length, "ERC1155: IDs and values must have same lengths");
        require(to != address(0), "ERC1155: target address must be non-zero");
        require(
            from == msg.sender || _operatorApprovals[from][msg.sender] == true,
            "ERC1155: need operator approval for 3rd party transfers."
        );

        for (uint256 i = 0; i < ids.length; ++i) {
            uint256 id = ids[i];
            uint256 value = values[i];

            _doTransfer(id, from, to, value);
        }

        emit TransferBatch(msg.sender, from, to, ids, values);

        _doSafeBatchTransferAcceptanceCheck(msg.sender, from, to, ids, values, data);
    }

    function _doTransfer(uint256 id, address from, address to, uint256 value) internal {
        address originalFrom = originalAddress(from);
        _balances[id][originalFrom] = _balances[id][originalFrom].sub(value);
        address originalTo = originalAddress(to);
        _balances[id][originalTo] = value.add(_balances[id][originalTo]);
    }

    modifier _isOracle(uint64 oracleId) {
        require(oracleOwnersMap[oracleId] == msg.sender, "Not the oracle owner.");
        _;
    }

    modifier _canTakeBequest(address from) {
        require(from == msg.sender || (block.timestamp < bequestTimes[from]),
                "Putting funds not approved.");
        _;
    }
}
