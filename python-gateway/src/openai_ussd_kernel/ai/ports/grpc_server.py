"""gRPC server implementing the AIBrain protobuf contract."""
import logging
from concurrent import futures

import grpc

from openai_ussd_kernel.ai.domain.personalization import UserContext
from openai_ussd_kernel.ai.domain.translation import TranslationRequest
from openai_ussd_kernel.ai.infrastructure.local_model import LocalModelAdapter
from openai_ussd_kernel.protos.v1.ai import ai_pb2, ai_pb2_grpc
from openai_ussd_kernel.protos.v1.common import common_pb2

logger = logging.getLogger(__name__)


class AIBrainServicer(ai_pb2_grpc.AIBrainServicer):
    """gRPC servicer for AI Brain — translates between protobuf and domain types."""

    def __init__(self, model_adapter: LocalModelAdapter) -> None:
        self._adapter = model_adapter

    def Translate(self, request, context):
        logger.info("Translate called", extra={"target_language": request.target_language})
        req = TranslationRequest(
            text=request.text,
            source_language=request.source_language or "en",
            target_language=request.target_language,
            tenant_id=request.tenant_id,
        )
        result = self._adapter.translate(req)
        return ai_pb2.TranslateResponse(
            translated_text=result.translated_text,
            source_language=result.source_language,
            target_language=result.target_language,
            confidence=result.confidence,
        )

    def Personalize(self, request, context):
        logger.info("Personalize called")
        user_ctx = UserContext(
            phone_number=request.phone_number,
            tenant_id=request.tenant_id,
            session_id=request.session_id or None,
            preferences=dict(request.user_context),
        )
        result = self._adapter.personalize(request.menu_text, user_ctx)
        return ai_pb2.PersonalizeResponse(
            personalized_text=result.personalized_text,
            hints_added=result.hints_added,
        )

    def Predict(self, request, context):
        logger.info("Predict called")
        # Stub: return the input as prediction with high confidence
        return ai_pb2.PredictResponse(
            prediction=request.input_features,
            confidence=0.95,
            model_version="ai-brain-v1",
        )

    def DetectIntent(self, request, context):
        logger.info("DetectIntent called")
        session_ctx = {}
        if request.session_context and request.session_context.fields:
            session_ctx = {k: v.string_value for k, v in request.session_context.fields.items()}
        intent = self._adapter.detect_intent(request.input_text, session_ctx)
        return ai_pb2.DetectIntentResponse(
            intent=intent.intent_type.value,
            confidence=intent.confidence,
            entities=intent.entities,
            raw_input=intent.raw_input,
        )

    def ExtractEntities(self, request, context):
        logger.info("ExtractEntities called")
        intent = self._adapter.detect_intent(request.input_text, {})
        return ai_pb2.ExtractEntitiesResponse(
            entities=[
                ai_pb2.Entity(label=k, value=v, confidence=intent.confidence)
                for k, v in intent.entities.items()
            ]
        )

    def SummarizeSession(self, request, context):
        logger.info("SummarizeSession called")
        events = []
        for ev in request.events:
            events.append({
                "event_type": ev.event_type,
                "aggregate_id": ev.aggregate_id,
                "timestamp": ev.occurred_at.seconds if ev.occurred_at else 0,
            })
        summary = self._adapter.summarize_session(events)
        return ai_pb2.SummarizeSessionResponse(
            summary_text=summary.get("summary", "Session summary unavailable."),
            key_actions=summary.get("key_actions", []),
            sentiment=summary.get("sentiment", "neutral"),
        )

    def GetEmbedding(self, request, context):
        logger.info("GetEmbedding called")
        vector = self._adapter.get_embedding(request.text)
        return ai_pb2.GetEmbeddingResponse(
            embedding=vector,
            model_id="ai-brain-v1",
        )

    def GetModelInfo(self, request, context):
        logger.info("GetModelInfo called")
        info = self._adapter.get_model_info(request.model_id)
        return ai_pb2.ModelInfo(
            model_id=info["model_id"],
            version=info["version"],
            language=info["language"],
            status=info["status"],
        )

    def ListModels(self, request, context):
        logger.info("ListModels called")
        models = self._adapter.list_models()
        return ai_pb2.ListModelsResponse(
            models=[
                ai_pb2.ModelInfo(
                    model_id=m["model_id"],
                    version=m["version"],
                    language=m["language"],
                    status=m["status"],
                )
                for m in models
            ]
        )

    def Health(self, request, context):
        import time
        from google.protobuf import timestamp_pb2
        return common_pb2.HealthResponse(
            status=common_pb2.HealthResponse.SERVING,
            version="1.0.0",
            timestamp=timestamp_pb2.Timestamp(seconds=int(time.time())),
        )


def serve(port: int = 50059, cert_file: str = None, key_file: str = None):
    server = grpc.server(futures.ThreadPoolExecutor(max_workers=10))
    adapter = LocalModelAdapter()
    ai_pb2_grpc.add_AIBrainServicer_to_server(AIBrainServicer(adapter), server)

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
    logger.info("AI Brain gRPC server started on port %s", port)
    server.wait_for_termination()


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO)
    serve()
