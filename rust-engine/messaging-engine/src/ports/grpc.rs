use std::collections::HashMap;

use tonic::{Request, Response, Status};
use tracing::{error, info, info_span, Instrument};

use ussd_kernel_common::v1::common::{
    health_response::ServingStatus, BatchItemError, BatchOperationResult, Error as ProtoError,
    HealthRequest, HealthResponse, PaginationMetadata,
};
use ussd_kernel_common::v1::messaging::messaging_service_server::MessagingService;
use ussd_kernel_common::v1::messaging::{
    GetMessageStatusRequest, GetMessageTemplateRequest, ListMessageTemplatesRequest,
    ListMessagesRequest, Message as ProtoMessage, MessageChannel as ProtoChannel,
    MessageStatus as ProtoStatus, MessageStatusResponse, MessageTemplate as ProtoTemplate,
    SendBatchMessagesRequest, SendEmailRequest, SendMessageResponse, SendSmsRequest,
    SendWhatsAppRequest, ListMessagesResponse, ListMessageTemplatesResponse,
};

use crate::application::handler::MessagingHandler;
use crate::domain::delivery::DeliveryStatus;
use crate::domain::message::{Message, MessageChannel, Priority};
use crate::ports::delivery_log::MessageFilters;

pub struct MessagingGrpcServer {
    handler: MessagingHandler,
}

impl MessagingGrpcServer {
    pub fn new(handler: MessagingHandler) -> Self {
        Self { handler }
    }
}

#[tonic::async_trait]
impl MessagingService for MessagingGrpcServer {
    async fn send_sms(
        &self,
        request: Request<SendSmsRequest>,
    ) -> Result<Response<SendMessageResponse>, Status> {
        let span = ussd_kernel_common::telemetry::extract_trace_context(request.metadata())
            .unwrap_or_else(|| info_span!("grpc_request"));
        let req = request.into_inner();

        async {
            info!("send_sms called");
            let tenant_id = parse_uuid(&req.tenant_id)?;
            let msg = Message {
                id: uuid::Uuid::new_v4(),
                recipient: req.to_number,
                body: req.message,
                channel: MessageChannel::Sms,
                priority: if req.flash {
                    Priority::High
                } else {
                    Priority::Normal
                },
                tenant_id,
                session_id: Some(req.session_id).filter(|s: &String| !s.is_empty()),
            };

            match self.handler.send_sms(msg).await {
                Ok(attempt) => Ok(Response::new(SendMessageResponse {
                    message_id: attempt.message_id.to_string(),
                    status: to_proto_status(attempt.status) as i32,
                    channel: ProtoChannel::Sms as i32,
                    sent_at: attempt.sent_at.map(to_prost_timestamp),
                    error: None,
                })),
                Err(e) => {
                    error!(error = %e, "send_sms failed");
                    Err(e.into())
                }
            }
        }
        .instrument(span)
        .await
    }

    async fn send_whats_app(
        &self,
        request: Request<SendWhatsAppRequest>,
    ) -> Result<Response<SendMessageResponse>, Status> {
        let span = ussd_kernel_common::telemetry::extract_trace_context(request.metadata())
            .unwrap_or_else(|| info_span!("grpc_request"));
        let req = request.into_inner();

        async {
            info!("send_whatsapp called");
            let tenant_id = parse_uuid(&req.tenant_id)?;
            let body = if !req.template_name.is_empty() {
                match self.handler.get_template(tenant_id, &req.template_name).await {
                    Ok(template) => {
                        crate::domain::template::render_template(&template, &req.template_params)
                    }
                    Err(_) => req.message,
                }
            } else {
                req.message
            };

            let msg = Message {
                id: uuid::Uuid::new_v4(),
                recipient: req.to_number,
                body,
                channel: MessageChannel::WhatsApp,
                priority: Priority::Normal,
                tenant_id,
                session_id: Some(req.session_id).filter(|s: &String| !s.is_empty()),
            };

            match self.handler.send_whatsapp(msg).await {
                Ok(attempt) => Ok(Response::new(SendMessageResponse {
                    message_id: attempt.message_id.to_string(),
                    status: to_proto_status(attempt.status) as i32,
                    channel: ProtoChannel::Whatsapp as i32,
                    sent_at: attempt.sent_at.map(to_prost_timestamp),
                    error: None,
                })),
                Err(e) => {
                    error!(error = %e, "send_whatsapp failed");
                    Err(e.into())
                }
            }
        }
        .instrument(span)
        .await
    }

    async fn send_email(
        &self,
        request: Request<SendEmailRequest>,
    ) -> Result<Response<SendMessageResponse>, Status> {
        let span = ussd_kernel_common::telemetry::extract_trace_context(request.metadata())
            .unwrap_or_else(|| info_span!("grpc_request"));
        let req = request.into_inner();

        async {
            info!("send_email called");
            let tenant_id = parse_uuid(&req.tenant_id)?;
            let body = format!("Subject: {}\n\n{}", req.subject, req.body);
            let msg = Message {
                id: uuid::Uuid::new_v4(),
                recipient: req.to_email,
                body,
                channel: MessageChannel::Email,
                priority: Priority::Normal,
                tenant_id,
                session_id: Some(req.session_id).filter(|s: &String| !s.is_empty()),
            };

            match self.handler.send_email(msg).await {
                Ok(attempt) => Ok(Response::new(SendMessageResponse {
                    message_id: attempt.message_id.to_string(),
                    status: to_proto_status(attempt.status) as i32,
                    channel: ProtoChannel::Email as i32,
                    sent_at: attempt.sent_at.map(to_prost_timestamp),
                    error: None,
                })),
                Err(e) => {
                    error!(error = %e, "send_email failed");
                    Err(e.into())
                }
            }
        }
        .instrument(span)
        .await
    }

    async fn send_batch_messages(
        &self,
        request: Request<SendBatchMessagesRequest>,
    ) -> Result<Response<BatchOperationResult>, Status> {
        let span = ussd_kernel_common::telemetry::extract_trace_context(request.metadata())
            .unwrap_or_else(|| info_span!("grpc_request"));
        let req = request.into_inner();

        async {
            info!("send_batch_messages called");
            let tenant_id = parse_uuid(&req.tenant_id)?;

            let messages: Vec<Message> = req
                .messages
                .into_iter()
                .map(|m| Message {
                    id: uuid::Uuid::new_v4(),
                    recipient: m.recipient,
                    body: m.message,
                    channel: from_proto_channel(m.channel).unwrap_or(MessageChannel::Sms),
                    priority: Priority::Normal,
                    tenant_id,
                    session_id: None,
                })
                .collect();

            match self.handler.send_batch(messages, req.continue_on_error).await {
                Ok(result) => {
                    let errors: Vec<BatchItemError> = result
                        .errors
                        .into_iter()
                        .map(|(idx, err)| BatchItemError {
                            index: idx as i32,
                            item_id: format!("batch-item-{}", idx),
                            error: Some(to_proto_error(err)),
                        })
                        .collect();

                    Ok(Response::new(BatchOperationResult {
                        batch_id: req.batch_id,
                        total_count: (result.success_count + result.failure_count) as i32,
                        success_count: result.success_count as i32,
                        failure_count: result.failure_count as i32,
                        errors,
                    }))
                }
                Err(e) => {
                    error!(error = %e, "send_batch_messages failed");
                    Err(e.into())
                }
            }
        }
        .instrument(span)
        .await
    }

    async fn get_message_status(
        &self,
        request: Request<GetMessageStatusRequest>,
    ) -> Result<Response<MessageStatusResponse>, Status> {
        let span = ussd_kernel_common::telemetry::extract_trace_context(request.metadata())
            .unwrap_or_else(|| info_span!("grpc_request"));
        let req = request.into_inner();

        async {
            info!("get_message_status called");
            let message_id = parse_uuid(&req.message_id)?;

            match self.handler.get_message_status(message_id).await {
                Ok(attempt) => Ok(Response::new(MessageStatusResponse {
                    message_id: attempt.message_id.to_string(),
                    status: to_proto_status(attempt.status) as i32,
                    channel: to_proto_channel(attempt.channel) as i32,
                    recipient: attempt.recipient,
                    sent_at: attempt.sent_at.map(to_prost_timestamp),
                    delivered_at: attempt.delivered_at.map(to_prost_timestamp),
                    read_at: None,
                    error_message: attempt.error_message.unwrap_or_default(),
                    retry_count: attempt.retry_count,
                    error: None,
                })),
                Err(e) => {
                    error!(error = %e, "get_message_status failed");
                    Err(e.into())
                }
            }
        }
        .instrument(span)
        .await
    }

    async fn list_messages(
        &self,
        request: Request<ListMessagesRequest>,
    ) -> Result<Response<ListMessagesResponse>, Status> {
        let span = ussd_kernel_common::telemetry::extract_trace_context(request.metadata())
            .unwrap_or_else(|| info_span!("grpc_request"));
        let req = request.into_inner();

        async {
            info!("list_messages called");
            let tenant_id = parse_uuid(&req.tenant_id)?;

            let filters = MessageFilters {
                channels: req
                    .channels
                    .iter()
                    .filter_map(|&c| from_proto_channel(c))
                    .collect(),
                statuses: req
                    .statuses
                    .iter()
                    .filter_map(|&s| from_proto_status(s))
                    .collect(),
                recipient: Some(req.recipient).filter(|s| !s.is_empty()),
                from_date: req.from_date.map(from_prost_timestamp),
                to_date: req.to_date.map(from_prost_timestamp),
                session_id: Some(req.session_id).filter(|s: &String| !s.is_empty()),
            };

            match self.handler.list_messages(tenant_id, filters).await {
                Ok(messages) => {
                    let proto_messages: Vec<ProtoMessage> = messages
                        .into_iter()
                        .map(|m| ProtoMessage {
                            message_id: m.id.to_string(),
                            channel: to_proto_channel(m.channel) as i32,
                            recipient: m.recipient,
                            content_preview: m.body.chars().take(100).collect(),
                            status: ProtoStatus::MessageQueued as i32,
                            sent_at: None,
                            delivered_at: None,
                            read_at: None,
                            tenant_id: m.tenant_id.to_string(),
                            session_id: m.session_id.unwrap_or_default(),
                        })
                        .collect();

                    let total_count = proto_messages.len() as i32;
                    Ok(Response::new(ListMessagesResponse {
                        messages: proto_messages,
                        pagination: Some(PaginationMetadata {
                            total_count,
                            next_page_token: String::new(),
                            previous_page_token: String::new(),
                            has_more: false,
                        }),
                        total_count,
                        error: None,
                    }))
                }
                Err(e) => {
                    error!(error = %e, "list_messages failed");
                    Err(e.into())
                }
            }
        }
        .instrument(span)
        .await
    }

    async fn get_message_template(
        &self,
        request: Request<GetMessageTemplateRequest>,
    ) -> Result<Response<ProtoTemplate>, Status> {
        let span = ussd_kernel_common::telemetry::extract_trace_context(request.metadata())
            .unwrap_or_else(|| info_span!("grpc_request"));
        let req = request.into_inner();

        async {
            info!("get_message_template called");
            let tenant_id = parse_uuid(&req.tenant_id)?;

            match self.handler.get_template(tenant_id, &req.template_id).await {
                Ok(template) => Ok(Response::new(to_proto_template(template))),
                Err(e) => {
                    error!(error = %e, "get_message_template failed");
                    Err(e.into())
                }
            }
        }
        .instrument(span)
        .await
    }

    async fn list_message_templates(
        &self,
        request: Request<ListMessageTemplatesRequest>,
    ) -> Result<Response<ListMessageTemplatesResponse>, Status> {
        let span = ussd_kernel_common::telemetry::extract_trace_context(request.metadata())
            .unwrap_or_else(|| info_span!("grpc_request"));
        let req = request.into_inner();

        async {
            info!("list_message_templates called");
            let tenant_id = parse_uuid(&req.tenant_id)?;
            let channel = from_proto_channel(req.channel);

            match self.handler.list_templates(tenant_id, channel).await {
                Ok(templates) => {
                    let proto_templates: Vec<ProtoTemplate> =
                        templates.into_iter().map(to_proto_template).collect();
                    let total_count = proto_templates.len() as i32;

                    Ok(Response::new(ListMessageTemplatesResponse {
                        templates: proto_templates,
                        pagination: Some(PaginationMetadata {
                            total_count,
                            next_page_token: String::new(),
                            previous_page_token: String::new(),
                            has_more: false,
                        }),
                        error: None,
                    }))
                }
                Err(e) => {
                    error!(error = %e, "list_message_templates failed");
                    Err(e.into())
                }
            }
        }
        .instrument(span)
        .await
    }

    async fn health(
        &self,
        _request: Request<HealthRequest>,
    ) -> Result<Response<HealthResponse>, Status> {
        Ok(Response::new(HealthResponse {
            status: ServingStatus::Serving as i32,
            version: env!("CARGO_PKG_VERSION").to_string(),
            timestamp: Some(prost_types::Timestamp::from(std::time::SystemTime::now())),
            dependencies: HashMap::new(),
            metadata: HashMap::new(),
        }))
    }
}

fn parse_uuid(s: &str) -> Result<uuid::Uuid, Status> {
    uuid::Uuid::parse_str(s).map_err(|e| Status::invalid_argument(format!("invalid uuid: {}", e)))
}

fn to_prost_timestamp(dt: chrono::DateTime<chrono::Utc>) -> prost_types::Timestamp {
    let system_time: std::time::SystemTime = dt.into();
    prost_types::Timestamp::from(system_time)
}

fn from_prost_timestamp(ts: prost_types::Timestamp) -> chrono::DateTime<chrono::Utc> {
    chrono::DateTime::from_timestamp(ts.seconds, ts.nanos as u32)
        .unwrap_or_else(|| chrono::Utc::now())
}

fn to_proto_channel(channel: MessageChannel) -> ProtoChannel {
    match channel {
        MessageChannel::Sms => ProtoChannel::Sms,
        MessageChannel::WhatsApp => ProtoChannel::Whatsapp,
        MessageChannel::Email => ProtoChannel::Email,
        MessageChannel::Push => ProtoChannel::Push,
    }
}

fn from_proto_channel(channel: i32) -> Option<MessageChannel> {
    match channel {
        1 => Some(MessageChannel::Sms),
        2 => Some(MessageChannel::WhatsApp),
        3 => Some(MessageChannel::Email),
        4 => Some(MessageChannel::Push),
        _ => None,
    }
}

fn to_proto_status(status: DeliveryStatus) -> ProtoStatus {
    match status {
        DeliveryStatus::Queued => ProtoStatus::MessageQueued,
        DeliveryStatus::Sent => ProtoStatus::MessageSent,
        DeliveryStatus::Delivered => ProtoStatus::MessageDelivered,
        DeliveryStatus::Read => ProtoStatus::MessageRead,
        DeliveryStatus::Failed => ProtoStatus::MessageFailed,
        DeliveryStatus::Rejected => ProtoStatus::MessageRejected,
        DeliveryStatus::Expired => ProtoStatus::MessageExpired,
        DeliveryStatus::Cancelled => ProtoStatus::MessageCancelled,
    }
}

fn from_proto_status(status: i32) -> Option<DeliveryStatus> {
    match status {
        1 => Some(DeliveryStatus::Queued),
        2 => Some(DeliveryStatus::Sent),
        3 => Some(DeliveryStatus::Delivered),
        4 => Some(DeliveryStatus::Read),
        5 => Some(DeliveryStatus::Failed),
        6 => Some(DeliveryStatus::Rejected),
        7 => Some(DeliveryStatus::Expired),
        8 => Some(DeliveryStatus::Cancelled),
        _ => None,
    }
}

fn to_proto_template(t: crate::domain::template::Template) -> ProtoTemplate {
    ProtoTemplate {
        template_id: t.id,
        tenant_id: t.tenant_id.to_string(),
        template_name: t.name,
        channel: to_proto_channel(t.channel) as i32,
        subject: t.subject.unwrap_or_default(),
        body: t.body,
        variables: t.variables,
        is_active: t.is_active,
        created_at: None,
        updated_at: None,
        error: None,
    }
}

fn to_proto_error(err: crate::domain::error::MessagingError) -> ProtoError {
    use ussd_kernel_common::v1::common::ErrorCode;
    let code = match &err {
        crate::domain::error::MessagingError::InvalidPhone(_) => ErrorCode::InvalidArgument,
        crate::domain::error::MessagingError::TemplateNotFound(_) => ErrorCode::NotFound,
        crate::domain::error::MessagingError::RateLimitExceeded(_) => {
            ErrorCode::RateLimitExceeded
        }
        crate::domain::error::MessagingError::ProviderUnavailable(_) => {
            ErrorCode::Unavailable
        }
        _ => ErrorCode::Internal,
    };

    ProtoError {
        code: code as i32,
        message: err.to_string(),
        details: HashMap::new(),
        trace_id: String::new(),
        grpc_code: tonic::Code::Internal as i32,
    }
}
