// SPDX-License-Identifier: LGPL-3.0-or-later
pragma solidity ^0.7.1;
import "./BaseBidOnAddresses.sol";

/// TODO: Allow the DAO to adjust registration date to pay salary retrospectively?
/// It would cause this effect: A scientist who is already great may register then his date is moved back
/// in time and instantly he or she receives a very big sum of money to his account.
/// If it is done erroneously, there may be no way to move the registration date again forward in time,
/// because the tokens may be already withdrawn. And it cannot be done in a fully decentralized way because
/// it needs oracles. So errors are seem inevitable. If there may be errors, maybe better not to allow it at all?
/// On the other hand, somebody malicious may create and register in my system a pool of Ethereum addresses that
// individuals can receive from them as if they themselves registered in the past.
/// So it in some cases (if the registration date is past the contract deployment) this issue is impossible to
/// mitigate.
/// But should we decide what to disallow to the global voters?
///
/// TODO: Should a salary recipient be able to transfer his salary receipt right to another user?
///       Should this transfer also update the token? (If it does, it makes no sense. If it doesn't, does it create a gain to kill him?)
contract BaseSalary is BaseBidOnAddresses {
    event CustomerRegistered(
        address customer,
        uint64 oracleId,
        bytes data
    );

    event SalaryMinted(
        address customer,
        uint64 oracleId,
        uint256 amount,
        bytes data
    );

    /// Mapping (original address => (oracle ID => (condition ID => registration time))).
    mapping(address => mapping(uint64 => mapping(uint256 => uint))) public registrationDates;
    /// Mapping (original address => (oracle ID => salary block time)).
    mapping(address => mapping(uint64 => mapping(uint256 => uint))) public lastSalaryDates;
    /// Mapping (condition ID => account) - salary recipients.
    mapping(uint256 => address) public salaryRecipients; // TODO: rename

    constructor(string memory uri_) BaseBidOnAddresses(uri_) { }

    function mintSalary(uint64 oracleId, uint64 condition, bytes calldata data)
        myConditional(condition) ensureLastConditionInChain(condition) external
    {
        uint lastSalaryDate = lastSalaryDates[msg.sender][oracleId][condition];
        require(lastSalaryDate != 0, "You are not registered.");
        // Note: Even if you withdraw once per 20 years, you will get only 630,720,000 tokens.
        // This number is probably not to big to be displayed well in UIs.
        uint256 amount = (lastSalaryDate - block.timestamp) * 10**18; // one token per second
        _mintToCustomer(msg.sender, condition, amount, data);
        lastSalaryDates[msg.sender][oracleId][condition] = block.timestamp;
        emit SalaryMinted(msg.sender, oracleId, amount, data);
    }

    /// Make a new condition that replaces the old one.
    /// It is useful to remove a trader's incentive to kill the issuer to reduce the circulating supply.
    /// The same can be done by transferring to yourself 0 tokens, but this method uses less gas.
    ///
    /// TODO: Should we recommend:
    /// - calling this function on each new project milestone?
    /// - calling this function regularly (e.g. every week)?
    ///
    /// This function also withdraws the old token.
    function recreateCondition(uint256 condition) public returns (uint256) {
        require(salaryRecipients[condition] == msg.sender, "Not the recipient.");
        return _recreateCondition(condition);
    }

    function _doCreateCondition(address customer) internal virtual override returns (uint256) {
        uint256 _conditionId = super._doCreateCondition(customer);
        salaryRecipients[_conditionId] = customer;
        return _conditionId;
    }

    /// Make a new condition that replaces the old one.
    /// The same can be done by transferring to yourself 0 tokens, but this method uses less gas.
    ///
    /// We need to create a new condition every time when an outgoimg transfer of a conditional token happens.
    /// Otherwise an investor would gain if he kills a scientist to reduce the circulating supply of his token to increase the price.
    /// Allowing old tokens to be exchangeable for new ones? (Allowing the reverse swap would create killer's gain.)
    /// Additional benefit of this solution: We can have different rewards at different stages of project,
    /// what may be benefical for early startups funding.
    /// TODO: There should be an advice to switch to a new token at each milestone of a project?
    ///
    /// Anyone can create a ERC-1155 contract that allows to use any of the tokens in the list
    /// by locking any of the tokens in the list as a new "general" token. We should recommend customers not to
    /// use such contracts, because it creates for them the killer exploit.
    ///
    /// If we would exchange the old and new tokens for the same amounts of collaterals, then it would be
    /// effectively the same token and therefore minting more new token would possibly devalue the old one,
    /// thus triggering the killer's exploit again. So we make old and new completely independent.
    ///
    /// Old token is 1:1 converted to the new token.
    function _recreateCondition(uint256 _condition)
        internal myConditional(_condition) ensureLastConditionInChain(_condition) returns (uint256)
    {
        address customer = salaryRecipients[_condition];
        uint256 _newCondition = _doCreateCondition(customer);
        firstConditionInChain[_newCondition] = firstConditionInChain[_condition];

        _balances[_newCondition][customer] = _balances[_condition][customer];
        _balances[_condition][customer] = 0;

        emit ConditionReCreate(customer, _condition, _newCondition);
        return _newCondition;
    }

    function _doTransfer(uint256 id, address from, address to, uint256 value) internal virtual override {
        super._doTransfer(id, from, to, value);

        if (id != 0 && salaryRecipients[id] == msg.sender) {
            if (isLastConditionInChain(id)) { // correct because `id != 0`
                _recreateCondition(id);
            }
        }
    }

    function _registerCustomer(address customer, uint64 oracleId, bytes calldata data) virtual internal {
        uint256 _condition = _doCreateCondition(customer);
        require(registrationDates[customer][oracleId][_condition] == 0, "You are already registered.");
        registrationDates[customer][oracleId][_condition] = block.timestamp;
        lastSalaryDates[customer][oracleId][_condition] = block.timestamp;
        emit CustomerRegistered(msg.sender, oracleId, data);
    }

    /// TODO: Move this declation.
    /// Must be called with `id != 0`.
    function isLastConditionInChain(uint256 id) internal view returns (bool) {
        return firstToLastConditionInChain[firstConditionInChain[id]] == id;
    }

    // TODO: It is always used to together with myConditional()
    modifier ensureLastConditionInChain(uint256 id) {
        require(id != 0 && isLastConditionInChain(id), "Only for the last salary token.");
        _;
    }
}