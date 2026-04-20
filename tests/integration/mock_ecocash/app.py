"""Mock EcoCash server for integration tests."""

import os
from flask import Flask, jsonify, request

app = Flask(__name__)


@app.route("/health", methods=["GET"])
def health():
    return jsonify({"status": "ok"}), 200


@app.route("/v1/payments/initiate", methods=["POST"])
def initiate_payment():
    data = request.get_json(silent=True) or {}
    return jsonify({
        "provider_reference": "ECO-12345",
        "status": "PENDING",
        "message": "OK"
    }), 200


@app.route("/v1/payments/status/<payment_id>", methods=["GET"])
def get_status(payment_id):
    return jsonify({
        "provider_reference": "ECO-12345",
        "status": "PENDING",
        "message": "OK"
    }), 200


if __name__ == "__main__":
    port = int(os.environ.get("PORT", "8080"))
    app.run(host="0.0.0.0", port=port)
