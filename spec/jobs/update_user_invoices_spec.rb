require 'spec_helper'

def travel_to(time)
  around { |example| Timecop.travel(start_of_july + time) { example.run } }
end

describe UpdateUserInvoices do
  describe "units specs" do
    let!(:start_of_july) { Time.now.beginning_of_year + 6.months }

    let!(:updater) { UpdateUserInvoices.new }

    let!(:user) { create(:user) }
    let!(:old_billable_period) { create(:billable_period, owner: user, begins_at: start_of_july - 1.month, ends_at: start_of_july) }
    let!(:billable_period1) { create(:billable_period, owner: user, begins_at: start_of_july, ends_at: start_of_july + 12.days) }
    let!(:billable_period2) { create(:billable_period, owner: user, begins_at: start_of_july + 12.days, ends_at: start_of_july + 20.days) }

    describe "perform" do
      let(:accounts_distributor) { double(:accounts_distributor) }
      before do
        allow(Enterprise).to receive(:find_by_id) { accounts_distributor }
        allow(updater).to receive(:update_invoice_for)
        allow(Bugsnag).to receive(:notify)
      end

      context "when necessary global config setting have not been set" do
        travel_to(20.days)

        context "when accounts_distributor has been set" do
          before do
            allow(Enterprise).to receive(:find_by_id) { false }
            updater.perform
          end

          it "snags errors and doesn't run" do
            expect(Bugsnag).to have_received(:notify).with(RuntimeError.new("InvalidJobSettings"), anything)
            expect(updater).to_not have_received(:update_invoice_for)
          end
        end
      end

      context "when necessary global config setting have been set" do
        context "on the first of the month" do
          travel_to(3.hours)

          it "updates the user's current invoice with billable_periods from the previous month" do
            updater.perform
            expect(updater).to have_received(:update_invoice_for).once
            .with(user, [old_billable_period])
          end
        end

        context "on other days" do
          travel_to(20.days)

          it "updates the user's current invoice with billable_periods from the current month" do
            updater.perform
            expect(updater).to have_received(:update_invoice_for).once
            .with(user, [billable_period1, billable_period2])
          end
        end

        context "when specfic start and end dates are passed as arguments" do
          let!(:updater) { UpdateUserInvoices.new(Time.now.year, 7) }

          before do
            allow(updater).to receive(:update_invoice_for)
          end

          context "that just ended (in the past)" do
            travel_to(1.month)

            it "updates the user's invoice with billable_periods from the previous month" do
              updater.perform
              expect(updater).to have_received(:update_invoice_for).once
              .with(user, [billable_period1, billable_period2])
            end
          end

          context "that starts in the past and ends in the future (ie. current_month)" do
            travel_to 30.days

            it "updates the user's invoice with billable_periods from that current month" do
              updater.perform
              expect(updater).to have_received(:update_invoice_for).once
              .with(user, [billable_period1, billable_period2])
            end
          end

          context "that starts in the future" do
            travel_to -1.days

            it "snags an error and does not update the user's invoice" do
              updater.perform
              expect(Bugsnag).to have_received(:notify).with(RuntimeError.new("InvalidJobSettings"), anything)
              expect(updater).to_not have_received(:update_invoice_for)
            end
          end
        end
      end
    end

    describe "update_invoice_for" do
      let(:invoice) { create(:order, user: user) }

      before do
        allow(user).to receive(:invoice_for) { invoice }
        allow(updater).to receive(:clean_up_and_save)
        allow(updater).to receive(:finalize)
        allow(Bugsnag).to receive(:notify)
      end

      context "on the first of the month" do
        travel_to(3.hours)

        before do
          allow(old_billable_period).to receive(:adjustment_label) { "Old Item" }
          allow(old_billable_period).to receive(:bill) { 666.66 }
        end

        context "where the invoice was not created at start_date" do
          before do
            invoice.update_attribute(:created_at, start_of_july - 1.month + 1.day)
            updater.update_invoice_for(user, [old_billable_period])
          end

          it "snags a bug" do
            expect(Bugsnag).to have_received(:notify)
          end
        end

        context "where the invoice was created at start_date" do
          before do
            invoice.update_attribute(:created_at, start_of_july - 1.month)
          end

          context "where the invoice is already complete" do
            before do
              allow(invoice).to receive(:complete?) { true }
              updater.update_invoice_for(user, [old_billable_period])
            end

            it "snags a bug" do
              expect(Bugsnag).to have_received(:notify)
            end
          end

          context "where the invoice is not complete" do
            before do
              allow(invoice).to receive(:complete?) { false }
              updater.update_invoice_for(user, [old_billable_period])
            end

            it "creates adjustments for each billing item" do
              adjustments = invoice.adjustments
              expect(adjustments.map(&:source_id)).to eq [old_billable_period.id]
              expect(adjustments.map(&:amount)).to eq [666.66]
              expect(adjustments.map(&:label)).to eq ["Old Item"]
            end

            it "cleans up and saves the invoice" do
              expect(updater).to have_received(:clean_up_and_save).with(invoice, anything).once
            end
          end
        end
      end

      context "on other days" do
        travel_to(20.days)

        before do
          allow(billable_period1).to receive(:adjustment_label) { "BP1 Item" }
          allow(billable_period2).to receive(:adjustment_label) { "BP2 Item" }
          allow(billable_period1).to receive(:bill) { 123.45 }
          allow(billable_period2).to receive(:bill) { 543.21 }
        end

        context "where the invoice was not created at start_date" do
          before do
            invoice.update_attribute(:created_at, start_of_july + 1.day)
            updater.update_invoice_for(user, [billable_period1, billable_period2])
          end

          it "snags a bug" do
            expect(Bugsnag).to have_received(:notify)
          end
        end

        context "where the invoice was created at start_date" do
          before do
            invoice.update_attribute(:created_at, start_of_july)
          end

          context "where the invoice is already complete" do
            before do
              allow(invoice).to receive(:complete?) { true }
              updater.update_invoice_for(user, [billable_period1, billable_period2])
            end

            it "snags a bug" do
              expect(Bugsnag).to have_received(:notify)
            end
          end

          context "where the invoice is not complete" do
            before do
              allow(invoice).to receive(:complete?) { false }
              updater.update_invoice_for(user, [billable_period1, billable_period2])
            end

            it "creates adjustments for each billing item" do
              adjustments = invoice.adjustments
              expect(adjustments.map(&:source_id)).to eq [billable_period1.id, billable_period2.id]
              expect(adjustments.map(&:amount)).to eq [123.45, 543.21]
              expect(adjustments.map(&:label)).to eq ["BP1 Item", "BP2 Item"]
            end

            it "cleans up and saves the invoice" do
              expect(updater).to have_received(:clean_up_and_save).with(invoice, anything).once
            end
          end
        end
      end
    end

    describe "clean_up_and_save" do
      let!(:invoice) { create(:order) }
      let!(:obsolete1) { create(:adjustment, adjustable: invoice) }
      let!(:obsolete2) { create(:adjustment, adjustable: invoice) }
      let!(:current1) { create(:adjustment, adjustable: invoice) }
      let!(:current2) { create(:adjustment, adjustable: invoice) }

      before do
        allow(invoice).to receive(:save)
        allow(invoice).to receive(:destroy)
        allow(Bugsnag).to receive(:notify)
      end

      context "when current adjustments are present" do
        let!(:current_adjustments) { [current1, current2] }

        context "and obsolete adjustments are present" do
          let!(:obsolete_adjustments) { [obsolete1, obsolete2] }

          before do
            allow(obsolete_adjustments).to receive(:destroy_all)
            allow(invoice).to receive(:adjustments) { double(:adjustments, where: obsolete_adjustments) }
            updater.clean_up_and_save(invoice, current_adjustments)
          end

          it "destroys obsolete adjustments and snags a bug" do
            expect(obsolete_adjustments).to have_received(:destroy_all)
            expect(Bugsnag).to have_received(:notify).with(RuntimeError.new("Obsolete Adjustments"), anything)
          end

          it "saves the invoice" do
            expect(invoice).to have_received(:save)
          end
        end

        context "and obsolete adjustments are not present" do
          let!(:obsolete_adjustments) { [] }

          before do
            allow(invoice).to receive(:adjustments) { double(:adjustments, where: obsolete_adjustments) }
            updater.clean_up_and_save(invoice, current_adjustments)
          end

          it "has no bugs to snag" do
            expect(Bugsnag).to_not have_received(:notify)
          end

          it "saves the invoice" do
            expect(invoice).to have_received(:save)
          end
        end
      end

      context "when current adjustments are not present" do
        let!(:current_adjustments) { [] }

        context "and obsolete adjustments are present" do
          let!(:obsolete_adjustments) { [obsolete1, obsolete2] }

          before do
            allow(obsolete_adjustments).to receive(:destroy_all)
            allow(invoice).to receive(:adjustments) { double(:adjustments, where: obsolete_adjustments) }
            updater.clean_up_and_save(invoice, current_adjustments)
          end

          it "destroys obsolete adjustments and snags a bug" do
            expect(obsolete_adjustments).to have_received(:destroy_all)
            expect(Bugsnag).to have_received(:notify).with(RuntimeError.new("Obsolete Adjustments"), anything)
          end

          it "destroys the invoice and snags a bug" do
            expect(invoice).to have_received(:destroy)
            expect(Bugsnag).to have_received(:notify).with(RuntimeError.new("Empty Persisted Invoice"), anything)
          end
        end

        context "and obsolete adjustments are not present" do
          let!(:obsolete_adjustments) { [] }

          before do
            allow(invoice).to receive(:adjustments) { double(:adjustments, where: obsolete_adjustments) }
            updater.clean_up_and_save(invoice, current_adjustments)
          end

          it "has no bugs to snag" do
            expect(Bugsnag).to_not have_received(:notify).with(RuntimeError.new("Obsolete Adjustments"), anything)
          end

          it "destroys the invoice and snags a bug" do
            expect(invoice).to have_received(:destroy)
            expect(Bugsnag).to have_received(:notify).with(RuntimeError.new("Empty Persisted Invoice"), anything)
          end
        end
      end
    end
  end

  describe "validation spec" do
    let!(:start_of_july) { Time.now.beginning_of_year + 6.months }

    let!(:updater) { UpdateUserInvoices.new }

    let!(:accounts_distributor) { create(:distributor_enterprise) }

    let!(:user) { create(:user) }
    let!(:billable_period1) { create(:billable_period, sells: 'any', owner: user, begins_at: start_of_july - 1.month, ends_at: start_of_july) }
    let!(:billable_period2) { create(:billable_period, owner: user, begins_at: start_of_july, ends_at: start_of_july + 10.days) }
    let!(:billable_period3) { create(:billable_period, owner: user, begins_at: start_of_july + 12.days, ends_at: start_of_july + 20.days) }

    before do
      Spree::Config.set({ accounts_distributor_id: accounts_distributor.id })
    end

    context "when no invoice currently exists" do
      context "when relevant billable periods exist" do
        travel_to(20.days)

        it "creates an invoice" do
          expect{updater.perform}.to change{Spree::Order.count}.from(0).to(1)
          invoice = user.orders.first
          expect(invoice.completed_at).to be_nil
          billable_adjustments = invoice.adjustments.where('source_type = (?)', 'BillablePeriod')
          expect(billable_adjustments.map(&:amount)).to eq [billable_period2.bill, billable_period3.bill]
          expect(invoice.total).to eq billable_period2.bill + billable_period3.bill
          expect(invoice.payments.count).to eq 0
          expect(invoice.state).to eq 'cart'
        end
      end

      context "when no relevant billable periods exist" do
        travel_to(1.month + 5.days)

        it "does not create an invoice" do
          expect{updater.perform}.to_not change{Spree::Order.count}.from(0)
        end
      end
    end

    context "when an invoice currently exists" do
      let!(:invoice) { create(:order, user: user, distributor: accounts_distributor, created_at: start_of_july) }
      let!(:billable_adjustment) { create(:adjustment, adjustable: invoice, source_type: 'BillablePeriod') }

      before do
        invoice.line_items.clear
      end

      context "when relevant billable periods exist" do
        travel_to(20.days)

        it "updates the invoice, and clears any obsolete invoices" do
          expect{updater.perform}.to_not change{Spree::Order.count}
          invoice = user.orders.first
          expect(invoice.completed_at).to be_nil
          billable_adjustments = invoice.adjustments.where('source_type = (?)', 'BillablePeriod')
          expect(billable_adjustments).to_not include billable_adjustment
          expect(billable_adjustments.map(&:amount)).to eq [billable_period2.bill, billable_period3.bill]
          expect(invoice.total).to eq billable_period2.bill + billable_period3.bill
          expect(invoice.payments.count).to eq 0
          expect(invoice.state).to eq 'cart'
        end
      end

      context "when no relevant billable periods exist" do
        travel_to(1.month + 5.days)

        it "destroys the invoice" do
          expect{updater.perform}.to_not change{Spree::Order.count}.from(1).to(0)
        end
      end
    end
  end
end