"""gRPC server implementing the USSDGateway protobuf contract."""
import logging
import os
import time
from concurrent import futures

import grpc
from google.protobuf import timestamp_pb2

from openai_ussd_kernel.gateway.handlers import ussd_callback
from openai_ussd_kernel.gateway.infrastructure.at_signature_validator import ATSignatureValidator
from openai_ussd_kernel.gateway.models import UssdRequest
from openai_ussd_kernel.protos.v1.common import common_pb2
from openai_ussd_kernel.protos.v1.gateway import gateway_pb2, gateway_pb2_grpc

logger = logging.getLogger(__name__)
_AT_API_KEY = os.environ.get("AFRICAS_TALKING_API_KEY", "")


class USSDGatewayServicer(gateway_pb2_grpc.USSDGatewayServicer):
    """gRPC servicer for USSD Gateway — allows internal services to initiate/manage USSD sessions."""

    def ReceiveUSSD(self, request, context):
        logger.info("ReceiveUSSD called via gRPC", extra={"session_id": request.session_id})
        # Convert gRPC request to internal UssdRequest
        ussd_req = UssdRequest(
            session_id=request.session_id,
            phone_number=request.phone_number,
            text=request.text,
            service_code=request.service_code,
            network_code=request.network_code,
        )
        response_text = ussd_callback(ussd_req)
        is_end = response_text.startswith("END ")
        body = response_text[4:] if response_text.startswith("CON ") or response_text.startswith("END ") else response_text
        return gateway_pb2.USSDResponse(
            session_id=request.session_id,
            response_text=body,
            is_end=is_end,
            type=gateway_pb2.USSDResponse.END if is_end else gateway_pb2.USSDResponse.CON,
        )

    def SendBatchUSSD(self, request, context):
        logger.info("SendBatchUSSD called", extra={"batch_id": request.batch_id, "count": len(request.messages)})
        # Stub: process each message and return batch result
        succeeded = 0
        failed = 0
        for msg in request.messages:
            # In production, this would queue each message for async processing
            succeeded += 1
        return common_pb2.BatchOperationResult(
            operation_id=request.batch_id,
            total_count=len(request.messages),
            success_count=succeeded,
            failed_count=failed,
            status=common_pb2.BatchOperationStatus.BATCH_COMPLETED,
        )

    def GetBatchStatus(self, request, context):
        logger.info("GetBatchStatus called", extra={"batch_id": request.batch_id})
        return gateway_pb2.BatchStatusResponse(
            batch_id=request.batch_id,
            status=gateway_pb2.BatchStatusResponse.COMPLETED,
            total_count=0,
            processed_count=0,
            failed_count=0,
        )

    def ProcessWebhook(self, request, context):
        logger.info("ProcessWebhook called", extra={"provider": request.provider_code})
        if request.provider_code == "africas_talking" and _AT_API_KEY and request.raw_payload:
            signature = request.request_headers.get("signature") or request.request_headers.get("x-at-signature")
            if signature:
                validator = ATSignatureValidator(_AT_API_KEY)
                if not validator.validate(request.raw_payload, signature):
                    return gateway_pb2.ProcessWebhookResponse(
                        accepted=False,
                        error="Invalid signature",
                    )
        return gateway_pb2.ProcessWebhookResponse(
            accepted=True,
            session_id=request.request_headers.get("session_id", ""),
            message="processed",
        )

    def ValidateWebhookSignature(self, request, context):
        logger.info("ValidateWebhookSignature called")
        validator = ATSignatureValidator(request.secret)
        is_valid = validator.validate(request.payload, request.signature)
        return gateway_pb2.ValidateWebhookSignatureResponse(
            valid=is_valid,
            error="" if is_valid else "Invalid signature",
        )

    def GetProviderAdapter(self, request, context):
        logger.info("GetProviderAdapter called", extra={"provider": request.provider_name})
        return gateway_pb2.ProviderAdapter(
            provider_name=request.provider_name,
            adapter_version="1.0.0",
            is_available=True,
            supported_channels=[gateway_pb2.ProviderAdapter.SMS, gateway_pb2.ProviderAdapter.USSD],
        )

    def ListProviderAdapters(self, request, context):
        logger.info("ListProviderAdapters called")
        return gateway_pb2.ListProviderAdaptersResponse(
            adapters=[
                gateway_pb2.ProviderAdapter(
                    provider_name="africas_talking",
                    adapter_version="1.0.0",
                    is_available=True,
                    supported_channels=[gateway_pb2.ProviderAdapter.SMS, gateway_pb2.ProviderAdapter.USSD],
                ),
                gateway_pb2.ProviderAdapter(
                    provider_name="ecocash",
                    adapter_version="1.0.0",
                    is_available=True,
                    supported_channels=[gateway_pb2.ProviderAdapter.MOBILE_MONEY],
                ),
            ]
        )

    def GetWebhookLog(self, request, context):
        logger.info("GetWebhookLog called")
        return gateway_pb2.WebhookLogEntry(
            log_id=request.log_id or "log-stub",
            webhook_id=request.webhook_id or "webhook-stub",
            status="delivered",
            http_status_code=200,
        )

    def ListWebhookLogs(self, request, context):
        logger.info("ListWebhookLogs called")
        return gateway_pb2.ListWebhookLogsResponse(
            logs=[],
            pagination=common_pb2.PaginationMetadata(total_count=0, has_more=False),
        )

    def GetDeadLetterQueue(self, request, context):
        logger.info("GetDeadLetterQueue called")
        return gateway_pb2.DeadLetterQueueResponse(
            messages=[],
            total_count=0,
        )

    def ReplayDeadLetter(self, request, context):
        logger.info("ReplayDeadLetter called", extra={"message_ids": list(request.message_ids)})
        return common_pb2.BatchOperationResult(
            operation_id="replay-stub",
            total_count=len(request.message_ids),
            success_count=len(request.message_ids),
            failed_count=0,
            status=common_pb2.BatchOperationStatus.BATCH_COMPLETED,
        )

    def Health(self, request, context):
        return common_pb2.HealthResponse(
            status=common_pb2.HealthResponse.SERVING,
            version="1.0.0",
            timestamp=timestamp_pb2.Timestamp(seconds=int(time.time())),
        )


def serve(port: int = 50056, cert_file: str = None, key_file: str = None):
    server = grpc.server(futures.ThreadPoolExecutor(max_workers=10))
    gateway_pb2_grpc.add_USSDGatewayServicer_to_server(USSDGatewayServicer(), server)

    if cert_file and key_file:
        with open(cert_file, "rb") as f:
            cert = f.read()
        with open(key_file, "rb") as f:
            key = f.read()
        creds = grpc.ssl_server_credentials(((key, cert),))
        server.add_secure_port(f"[::]:{port}", creds)
    else:
        server.add_insecure_port(f"[::]:{port}")

    server.start()
    logger.info("USSD Gateway gRPC server started on port %s", port)
    server.wait_for_termination()


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO)
    serve()
