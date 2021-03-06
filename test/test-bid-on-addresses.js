"strict";

// TODO: This test needs to be rewritten for the new contract API.

const { expectRevert } = require("openzeppelin-test-helpers");
const { toBN } = web3.utils;
const {
  INITIAL_CUSTOMER_BALANCE,
  conditionalTokenId
} = require("../utils/bin-on-addresses-helpers")(web3.utils);

const BidOnAddresses = artifacts.require("BidOnAddresses");
const ERC1155Mintable = artifacts.require("ERC1155Mock");

contract("BidOnAddresses", function(accounts) {
  const [oracle1, customer1, customer2, donor1, donor2] = accounts;

  beforeEach("initiate token contracts", async function() {
    this.conditionalTokens = await BidOnAddresses.new("https://example.com/2");
    this.collateralContract = await ERC1155Mintable.new(
      "https://example.com/2"
    ); // TODO: Check multiple collaterals
    this.collateralTokenId = 123; // arbitrary
    this.collateralContract.mint(
      donor1,
      this.collateralTokenId,
      "1000000000000000000000",
      []
    );
    this.collateralContract.mint(
      donor2,
      this.collateralTokenId,
      "1000000000000000000000",
      []
    );

    ({ logs: this.logs1 } = await this.conditionalTokens.createOracle({
      from: oracle1
    }));
    this.oracleId1 = this.logs1[0].args.oracleId;
    ({ logs: this.logs2 } = await this.conditionalTokens.createOracle({
      from: oracle1
    }));
    this.oracleId2 = this.logs2[0].args.oracleId;

    const farFuture = toBN(2).pow(toBN(64));
    await this.conditionalTokens.updateGracePeriodEnds(
      this.oracleId1,
      farFuture
    );
    await this.conditionalTokens.updateGracePeriodEnds(
      this.oracleId2,
      farFuture
    );
    // TODO: Test withdrawals after grace period.
  });

  describe("main test", function() {
    context("with valid parameters", function() {
      it("should leave payout denominator unset", async function() {
        (
          await this.conditionalTokens.payoutDenominator(this.oracleId1)
        ).should.be.bignumber.equal("0");
        (
          await this.conditionalTokens.payoutDenominator(this.oracleId2)
        ).should.be.bignumber.equal("0");
      });

      it("should not be able to register the same customer more than once for the same oracleId", async function() {
        await this.conditionalTokens.registerCustomer(this.oracleId1, [], {
          from: customer1
        });
        await expectRevert(
          this.conditionalTokens.registerCustomer(this.oracleId1, [], {
            from: customer1
          }),
          "customer already registered"
        );
      });

      it("checking the math", async function() {
        const customers = [customer1, customer2];
        const oracleIdsInfo = [
          {
            oracleId: this.oracleId1,
            numerators: [{ numerator: toBN("45") }, { numerator: toBN("60") }]
          },
          {
            oracleId: this.oracleId2,
            numerators: [{ numerator: toBN("33") }, { numerator: toBN("90") }]
          }
        ];
        // TODO: Simplify customers array.
        const products = [
          {
            oracleId: 0,
            donors: [
              { account: donor1, amount: toBN("10000000000") },
              { account: donor2, amount: toBN("1000000000000") }
            ],
            customers: [{ account: 0 }, { account: 1 }]
          },
          {
            oracleId: 1,
            donors: [
              { account: donor1, amount: toBN("20000000000") },
              { account: donor2, amount: toBN("2000000000000") }
            ],
            customers: [{ account: 0 }, { account: 1 }]
          }
        ];

        async function setupOneProduct(product) {
          for (let donor of product.donors) {
            await this.collateralContract.setApprovalForAll(
              this.conditionalTokens.address,
              true,
              { from: donor.account }
            );
            const oracleIdInfo = oracleIdsInfo[product.oracleId];
            await this.conditionalTokens.donate(
              this.collateralContract.address,
              this.collateralTokenId,
              oracleIdInfo.oracleId,
              donor.amount,
              donor.account,
              donor.account,
              [],
              { from: donor.account }
            );
          }

          // To complicate the task of the test, we will transfer some tokens from the first customer to the rest.
          async function transferSomeConditional(amount) {
            for (let i = 1; i != customers.length; ++i) {
              await this.conditionalTokens.safeTransferFrom(
                customers[0],
                customers[i],
                conditionalTokenId(product.oracleId, customers[0]),
                amount,
                [],
                { from: customers[0] }
              );
            }
          }

          await transferSomeConditional.bind(this)(web3.utils.toWei("2.3"));

          const oracleIdInfo = oracleIdsInfo[product.oracleId];
          for (let i in oracleIdInfo.numerators) {
            await this.conditionalTokens.reportNumerator(
              oracleIdInfo.oracleId,
              customers[i],
              oracleIdInfo.numerators[i].numerator,
              { from: oracle1 }
            );
          }
          await this.conditionalTokens.finishOracle(oracleIdInfo.oracleId);

          await transferSomeConditional.bind(this)(web3.utils.toWei("1.2"));
        }

        async function redeemOneProduct(product) {
          const oracleIdInfo = oracleIdsInfo[product.oracleId];
          let totalCollateral = toBN("0");
          for (let donor of product.donors) {
            totalCollateral = totalCollateral.add(donor.amount);
          }
          let denominator = toBN("0");
          for (let n of oracleIdInfo.numerators) {
            denominator = denominator.add(n.numerator);
          }
          (
            await this.conditionalTokens.payoutDenominator(
              oracleIdInfo.oracleId
            )
          ).should.be.bignumber.equal(denominator);
          for (let customer of product.customers) {
            const oracleIdInfo = oracleIdsInfo[product.oracleId];
            const account = customers[customer.account];
            const initialCollateralBalance = await this.conditionalTokens.collateralOwing(
              this.collateralContract.address,
              this.collateralTokenId,
              oracleIdInfo.oracleId,
              account,
              account
            );
            initialCollateralBalance
              .sub(
                totalCollateral
                  .mul(oracleIdInfo.numerators[customer.account].numerator)
                  .mul(
                    await this.conditionalTokens.balanceOf(
                      account,
                      conditionalTokenId(product.oracleId, account)
                    )
                  )
                  .div(denominator)
                  .div(INITIAL_CUSTOMER_BALANCE)
              )
              .abs()
              .should.be.bignumber.below(toBN("2"));

            // TODO: Redeem somebody other's token.
            const oldBalance = await this.collateralContract.balanceOf(
              account,
              this.collateralTokenId
            );
            await this.conditionalTokens.withdrawCollateral(
              this.collateralContract.address,
              this.collateralTokenId,
              oracleIdInfo.oracleId,
              account,
              [],
              { from: account }
            );

            const newBalance = await this.collateralContract.balanceOf(
              account,
              this.collateralTokenId
            );
            newBalance
              .sub(oldBalance)
              .should.be.bignumber.equal(initialCollateralBalance);

            // Should do nothing.
            await this.conditionalTokens.withdrawCollateral(
              this.collateralContract.address,
              this.collateralTokenId,
              oracleIdInfo.oracleId,
              account,
              [],
              { from: account }
            );
          }
        }

        for (let customer of customers) {
          await this.conditionalTokens.registerCustomer(this.oracleId1, [], {
            from: customer
          });
          await this.conditionalTokens.registerCustomer(this.oracleId2, [], {
            from: customer
          });
        }

        // Can be written shorter:
        // Promise.all(products.map(testOneProduct.bind(this)));
        // But let us be on reliability side:
        for (let product of products) {
          await setupOneProduct.bind(this)(product);
        }
        for (let product of products) {
          await redeemOneProduct.bind(this)(product);
        }

        // TODO
      });

      // TODO: Unregistered customer receives zero.
      // TODO: Send money to registered and unregistered customers.
      // TODO: reportNumerator() called second time for the same customer.
      // TODO: Test all functions and all variants.
      // TODO: Donating/staking from other's approved account.
    });
  });
});
