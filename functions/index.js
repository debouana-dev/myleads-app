const { onCall, HttpsError } = require('firebase-functions/v2/https');
const { defineSecret } = require('firebase-functions/params');
const { initializeApp } = require('firebase-admin/app');
const Stripe = require('stripe');

initializeApp();

// Declare the secret — Cloud Secret Manager provisions it automatically.
// Provision before first deploy:  firebase functions:secrets:set STRIPE_SECRET_KEY
// Local emulation: add STRIPE_SECRET_KEY=sk_test_... to functions/.secret.local
const stripeSecretKey = defineSecret('STRIPE_SECRET_LIVE_KEY');

const ALLOWED_PLANS = ['premium', 'business'];
const ALLOWED_CYCLES = ['monthly', 'yearly'];

// Price map in EUR cents — keep in sync with StripeService in the Flutter app.
// Stripe requires integer amounts in the smallest currency unit (1 EUR = 100 cents).
const PRICES = {
  premium:  { monthly: 359,  yearly: 3588 },
  business: { monthly: 719,  yearly: 7188 },
};

/**
 * Creates a Stripe Payment Intent and returns its client secret.
 * Called by StripeService.startCheckout() in the Flutter app.
 *
 * Request data: { plan, billingCycle, amount, currency }
 * Returns:      { clientSecret, paymentIntentId }
 */
exports.createPaymentIntent = onCall(
  { region: 'europe-west1', invoker: 'public', enforceAppCheck: false, secrets: [stripeSecretKey] },
  async (request) => {
    const stripe = Stripe(stripeSecretKey.value());
    const { plan, billingCycle, currency = 'eur' } = request.data;

    if (!ALLOWED_PLANS.includes(plan)) {
      throw new HttpsError('invalid-argument', `Unknown plan: ${plan}`);
    }
    if (!ALLOWED_CYCLES.includes(billingCycle)) {
      throw new HttpsError('invalid-argument', `Unknown billing cycle: ${billingCycle}`);
    }

    const rawLicenseCount = request.data.licenseCount;
    const licenseCount = rawLicenseCount == null ? 1 : Number(rawLicenseCount);
    if (!Number.isInteger(licenseCount) || licenseCount < 1) {
      throw new HttpsError('invalid-argument', 'licenseCount must be an integer >= 1');
    }

    const rawAmount = request.data.amount;
    let amount;
    if (rawAmount != null) {
      const parsedAmount = Number(rawAmount);
      if (!Number.isFinite(parsedAmount) || parsedAmount < 1) {
        throw new HttpsError('invalid-argument', 'amount must be a number >= 1');
      }
      amount = Math.round(parsedAmount);
    } else {
      amount = PRICES[plan][billingCycle] * licenseCount;
    }

    const paymentIntent = await stripe.paymentIntents.create({
      amount,
      currency,
      automatic_payment_methods: { enabled: true },
      metadata: { plan, billingCycle, licenseCount },
    });

    return {
      clientSecret: paymentIntent.client_secret,
      paymentIntentId: paymentIntent.id,
    };
  }
);

/**
 * Returns the current status of a Payment Intent.
 * Used by the Flutter app to verify payment outcome after returning from a
 * Link or bank-redirect browser flow where the PaymentSheet was dismissed.
 *
 * Request data: { paymentIntentId }
 * Returns:      { status }  — Stripe PaymentIntent status string
 */
exports.getPaymentStatus = onCall(
  { region: 'europe-west1', invoker: 'public', enforceAppCheck: false, secrets: [stripeSecretKey] },
  async (request) => {
    const { paymentIntentId } = request.data;
    if (!paymentIntentId || typeof paymentIntentId !== 'string') {
      throw new HttpsError('invalid-argument', 'Missing or invalid paymentIntentId');
    }
    const stripe = Stripe(stripeSecretKey.value());
    const pi = await stripe.paymentIntents.retrieve(paymentIntentId);
    return { status: pi.status };
  }
);
