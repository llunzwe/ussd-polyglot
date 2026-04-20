# Tenant SDK (Python) Implementation Guide

**Version**: 1.0.0  
**Language**: Python 3.10+  
**Status**: Implementation Ready  

---

## 1. SDK Overview

The Python SDK enables tenant developers to build USSD applications without managing the underlying infrastructure complexity.

### Key Features

- **Decorator-based menus**: `@ussd.menu("main")`
- **Automatic session persistence**: Session state auto-saved to ledger
- **Payment integration**: One-line payment initiation
- **AI integration**: Translation and personalization
- **Type hints**: Full IDE support

---

## 2. Installation

```bash
pip install openai-ussd-kernel-sdk
```

### Dependencies

```
openai-ussd-kernel-sdk>=1.0.0
grpcio>=1.62.0
pydantic>=2.0.0
python-dotenv>=1.0.0
```

---

## 3. Quick Start

### 3.1 Minimal Application

```python
# app.py
from kernel_sdk import KernelApp, ussd

app = KernelApp(
    name="My USSD App",
    tenant_id="my_tenant_123",
    api_key="tenant-api-key-here"
)

@ussd.menu("main", welcome=True)
def main_menu(session, user_input):
    if user_input == "":
        return ussd.MenuResponse(
            message="Welcome!\n1. Check Balance\n2. Send Money\n3. Exit",
            options=["Check Balance", "Send Money", "Exit"]
        )
    elif user_input == "1":
        return ussd.goto("check_balance")
    elif user_input == "2":
        return ussd.goto("send_money")
    elif user_input == "3":
        return ussd.end_session("Thank you for using our service!")
    else:
        return ussd.MenuResponse(
            message="Invalid option. Please try again.",
            type="CON"
        )

@ussd.menu("check_balance")
def check_balance(session, user_input):
    balance = get_user_balance(session.get("phone_number"))
    return ussd.end_session(f"Your balance is: ${balance:.2f}")

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=9000)
```

### 3.2 Configuration

```python
# config.py
from pydantic_settings import BaseSettings

class Settings(BaseSettings):
    # Kernel connection
    KERNEL_HOST: str = "localhost"
    KERNEL_PORT: int = 9090
    KERNEL_API_KEY: str
    
    # Tenant configuration
    TENANT_ID: str
    TENANT_NAME: str
    
    # Service configuration
    PORT: int = 9000
    LOG_LEVEL: str = "INFO"
    
    class Config:
        env_file = ".env"

settings = Settings()
```

```bash
# .env
KERNEL_HOST=go-orchestrator.ussd-kernel.svc.cluster.local
KERNEL_PORT=9090
KERNEL_API_KEY=sk_live_...
TENANT_ID=microfinance_zim
TENANT_NAME=MicroFinance Zimbabwe
PORT=9000
```

---

## 4. Core Components

### 4.1 KernelApp Class

```python
# kernel_sdk/app.py
import logging
from typing import Optional, Callable, Dict, Any
import grpc
from concurrent import futures

from .grpc import tenant_pb2, tenant_pb2_grpc
from .session import SessionManager
from .router import MenuRouter

logger = logging.getLogger(__name__)

class KernelApp:
    """Main application class for USSD tenants."""
    
    def __init__(
        self,
        name: str,
        tenant_id: str,
        api_key: str,
        kernel_host: str = "localhost",
        kernel_port: int = 9090,
        **kwargs
    ):
        self.name = name
        self.tenant_id = tenant_id
        self.api_key = api_key
        self.kernel_host = kernel_host
        self.kernel_port = kernel_port
        
        # Components
        self.menu_router = MenuRouter()
        self.session_manager = SessionManager(
            tenant_id=tenant_id,
            kernel_host=kernel_host,
            kernel_port=kernel_port
        )
        
        # gRPC server
        self._server = None
        self._port = kwargs.get('port', 9000)
        
    def run(self, host: str = "0.0.0.0", port: int = None):
        """Start the gRPC server."""
        port = port or self._port
        
        self._server = grpc.server(futures.ThreadPoolExecutor(max_workers=10))
        tenant_pb2_grpc.add_TenantUSSDAppServicer_to_server(
            TenantService(self),
            self._server
        )
        self._server.add_insecure_port(f"{host}:{port}")
        
        self._server.start()
        logger.info(f"🚀 {self.name} running on {host}:{port}")
        
        try:
            self._server.wait_for_termination()
        except KeyboardInterrupt:
            self._server.stop(0)

class TenantService(tenant_pb2_grpc.TenantUSSDAppServicer):
    """gRPC service implementation."""
    
    def __init__(self, app: KernelApp):
        self.app = app
        
    def HandleMenu(self, request, context):
        """Handle USSD menu request from kernel."""
        try:
            # Get or create session
            session = self.app.session_manager.get_session(
                request.session_id,
                request.phone_number
            )
            
            # Route to menu handler
            handler = self.app.menu_router.get_handler(request.current_menu)
            
            if handler is None:
                return tenant_pb2.MenuResponse(
                    type=tenant_pb2.MenuResponse.END,
                    message="System error. Please try again later."
                )
            
            # Call handler
            response = handler(session, request.user_input)
            
            # Update session state
            self.app.session_manager.update_session(
                request.session_id,
                response.updated_state
            )
            
            # Convert response
            return self._convert_response(response)
            
        except Exception as e:
            logger.exception("Error handling menu request")
            return tenant_pb2.MenuResponse(
                type=tenant_pb2.MenuResponse.END,
                message="An error occurred. Please try again."
            )
    
    def _convert_response(self, response) -> tenant_pb2.MenuResponse:
        """Convert SDK response to gRPC response."""
        proto_response = tenant_pb2.MenuResponse()
        
        proto_response.type = (
            tenant_pb2.MenuResponse.CON 
            if response.type == "CON" 
            else tenant_pb2.MenuResponse.END
        )
        proto_response.message = response.message
        proto_response.next_menu = response.next_menu
        
        # Convert options
        for opt in response.options:
            proto_opt = proto_response.options.add()
            proto_opt.id = opt.id
            proto_opt.label = opt.label
            
        # Convert state
        for key, value in (response.updated_state or {}).items():
            proto_response.updated_state[key] = str(value)
            
        return proto_response
```

### 4.2 Session Management

```python
# kernel_sdk/session.py
from typing import Dict, Any, Optional
import grpc
from dataclasses import dataclass, field

from .grpc import orchestrator_pb2, orchestrator_pb2_grpc

@dataclass
class Session:
    """USSD session object."""
    session_id: str
    phone_number: str
    tenant_id: str
    data: Dict[str, Any] = field(default_factory=dict)
    version: int = 0
    
    def get(self, key: str, default=None):
        """Get value from session."""
        return self.data.get(key, default)
    
    def set(self, key: str, value: Any):
        """Set value in session."""
        self.data[key] = value
        
    def delete(self, key: str):
        """Delete key from session."""
        self.data.pop(key, None)
        
    def emit_event(self, event_type: str, payload: Dict[str, Any]):
        """Emit custom event to ledger."""
        # Implementation would call kernel's AppendEvent
        pass

class SessionManager:
    """Manages USSD sessions."""
    
    def __init__(self, tenant_id: str, kernel_host: str, kernel_port: int):
        self.tenant_id = tenant_id
        self.channel = grpc.insecure_channel(f"{kernel_host}:{kernel_port}")
        self.stub = orchestrator_pb2_grpc.OrchestratorStub(self.channel)
        
    def get_session(self, session_id: str, phone_number: str) -> Session:
        """Get session from kernel."""
        request = orchestrator_pb2.GetSessionStateRequest(
            session_id=session_id,
            tenant_id=self.tenant_id
        )
        
        try:
            response = self.stub.GetSessionState(request)
            
            # Convert proto struct to dict
            data = dict(response.state) if response.state else {}
            
            return Session(
                session_id=session_id,
                phone_number=phone_number,
                tenant_id=self.tenant_id,
                data=data,
                version=response.current_version
            )
        except grpc.RpcError as e:
            # Session not found, create new
            return Session(
                session_id=session_id,
                phone_number=phone_number,
                tenant_id=self.tenant_id
            )
    
    def update_session(self, session_id: str, state: Dict[str, Any]):
        """Update session state in kernel."""
        # This is handled implicitly through menu responses
        # The kernel persists state changes
        pass
```

### 4.3 Menu Router

```python
# kernel_sdk/router.py
from typing import Dict, Callable, Optional
import inspect

class MenuRouter:
    """Routes USSD requests to menu handlers."""
    
    def __init__(self):
        self._handlers: Dict[str, Callable] = {}
        self._welcome_menu: Optional[str] = None
        
    def register(self, menu_name: str, handler: Callable, welcome: bool = False):
        """Register a menu handler."""
        self._handlers[menu_name] = handler
        
        if welcome:
            self._welcome_menu = menu_name
            
    def get_handler(self, menu_name: str) -> Optional[Callable]:
        """Get handler for menu name."""
        # Default to welcome menu if not found
        handler = self._handlers.get(menu_name)
        if handler is None and self._welcome_menu:
            handler = self._handlers.get(self._welcome_menu)
        return handler
```

### 4.4 Decorators

```python
# kernel_sdk/decorators.py
from functools import wraps
from typing import Callable, List, Optional

from .router import global_router

class MenuResponse:
    """Response from a menu handler."""
    
    def __init__(
        self,
        message: str,
        type: str = "CON",  # CON or END
        options: Optional[List[dict]] = None,
        next_menu: Optional[str] = None,
        updated_state: Optional[dict] = None
    ):
        self.message = message
        self.type = type
        self.options = options or []
        self.next_menu = next_menu
        self.updated_state = updated_state or {}

class ussd:
    """USSD decorator namespace."""
    
    @staticmethod
    def menu(name: str, welcome: bool = False):
        """Decorator to register a menu handler."""
        def decorator(func: Callable):
            global_router.register(name, func, welcome)
            
            @wraps(func)
            def wrapper(*args, **kwargs):
                return func(*args, **kwargs)
            return wrapper
        return decorator
    
    @staticmethod
    def goto(menu_name: str, preserve_state: bool = True):
        """Navigate to another menu."""
        return MenuResponse(
            message="",  # Will be filled by target menu
            type="CON",
            next_menu=menu_name
        )
    
    @staticmethod
    def end_session(message: str):
        """End the USSD session."""
        return MenuResponse(
            message=message,
            type="END"
        )
```

---

## 5. Payment Integration

### 5.1 Receiving Payments

```python
# payments.py
from kernel_sdk import payment

@ussd.menu("payment_amount")
def payment_amount(session, user_input):
    if not user_input:
        return ussd.MenuResponse(
            message="Enter amount to pay:",
            type="CON"
        )
    
    # Validate amount
    try:
        amount = float(user_input)
        if amount <= 0:
            raise ValueError()
    except ValueError:
        return ussd.MenuResponse(
            message="Invalid amount. Please enter a number:",
            type="CON"
        )
    
    session.set("payment_amount", amount)
    return ussd.goto("payment_confirm")

@ussd.menu("payment_confirm")
def payment_confirm(session, user_input):
    amount = session.get("payment_amount")
    
    if user_input == "":
        return ussd.MenuResponse(
            message=f"Pay ${amount:.2f}?\n1. Confirm\n2. Cancel",
            options=["Confirm", "Cancel"],
            type="CON"
        )
    
    if user_input == "1":
        # Initiate payment
        result = payment.initiate(
            provider="ecocash",
            phone=session.get("phone_number"),
            amount=amount,
            reference=f"payment_{session.session_id}",
            description="Service payment"
        )
        
        if result.success:
            session.set("payment_id", result.payment_id)
            return ussd.goto("payment_processing")
        else:
            return ussd.end_session(f"Payment failed: {result.error_message}")
    
    elif user_input == "2":
        return ussd.end_session("Payment cancelled.")
    
    else:
        return ussd.MenuResponse(
            message="Invalid option. Please try again.",
            type="CON"
        )
```

### 5.2 Payment Module

```python
# kernel_sdk/payment.py
from dataclasses import dataclass
from typing import Optional
import grpc

from .grpc import payment_pb2, payment_pb2_grpc

@dataclass
class PaymentResult:
    success: bool
    payment_id: Optional[str] = None
    status: Optional[str] = None
    error_message: Optional[str] = None

def initiate(
    provider: str,
    phone: str,
    amount: float,
    reference: str,
    description: str = "",
    tenant_id: str = None
) -> PaymentResult:
    """Initiate a mobile money payment."""
    
    # Get config from context
    from .app import current_app
    app = current_app()
    
    channel = grpc.insecure_channel(
        f"{app.kernel_host}:{app.kernel_port}"
    )
    stub = payment_pb2_grpc.PaymentEngineStub(channel)
    
    request = payment_pb2.InitiatePaymentRequest(
        provider=parse_provider(provider),
        phone_number=phone,
        amount=payment_pb2.Money(
            currency_code="USD",
            amount_cents=int(amount * 100)
        ),
        reference=reference,
        description=description,
        tenant_id=tenant_id or app.tenant_id
    )
    
    try:
        response = stub.InitiatePayment(request)
        
        return PaymentResult(
            success=response.status == payment_pb2.InitiatePaymentResponse.COMPLETED,
            payment_id=response.payment_id,
            status=response.status,
            error_message=response.error.message if response.error else None
        )
    except grpc.RpcError as e:
        return PaymentResult(
            success=False,
            error_message=str(e)
        )

def parse_provider(provider: str) -> int:
    """Parse provider string to enum."""
    providers = {
        "ecocash": 1,
        "onemoney": 2,
        "telecash": 3
    }
    return providers.get(provider.lower(), 0)
```

---

## 6. AI Integration

### 6.1 Translation

```python
# kernel_sdk/ai.py
import grpc
from .grpc import ai_pb2, ai_pb2_grpc

def translate(text: str, target_language: str) -> str:
    """Translate text to target language."""
    from .app import current_app
    app = current_app()
    
    channel = grpc.insecure_channel(
        f"{app.kernel_host}:{app.kernel_port}"
    )
    stub = ai_pb2_grpc.AIBrainStub(channel)
    
    request = ai_pb2.TranslateRequest(
        text=text,
        target_language=target_language
    )
    
    response = stub.Translate(request)
    return response.translated_text

def personalize(menu_text: str, user_context: dict) -> str:
    """Personalize menu text based on user context."""
    # Implementation would call AI service
    pass
```

### 6.2 Usage in Menu

```python
@ussd.menu("main", welcome=True)
def main_menu(session, user_input):
    lang = session.get("language", "en")
    
    menu_text = "Welcome!\n1. Check Balance\n2. Send Money\n3. Exit"
    
    # Translate if needed
    if lang != "en":
        menu_text = ai.translate(menu_text, lang)
    
    return ussd.MenuResponse(
        message=menu_text,
        options=[
            {"id": "1", "label": ai.translate("Check Balance", lang)},
            {"id": "2", "label": ai.translate("Send Money", lang)},
            {"id": "3", "label": ai.translate("Exit", lang)}
        ],
        type="CON"
    )
```

---

## 7. Testing

### 7.1 Unit Testing

```python
# tests/test_menus.py
import pytest
from kernel_sdk.testing import MockSession, MockKernel

@pytest.fixture
def mock_kernel():
    return MockKernel()

def test_main_menu_welcome(mock_kernel):
    session = MockSession(
        session_id="test-123",
        phone_number="+263712345678"
    )
    
    response = main_menu(session, "")
    
    assert response.type == "CON"
    assert "Welcome" in response.message
    assert len(response.options) == 3

def test_main_menu_option_1(mock_kernel):
    session = MockSession(
        session_id="test-123",
        phone_number="+263712345678"
    )
    
    response = main_menu(session, "1")
    
    assert response.next_menu == "check_balance"
```

### 7.2 Integration Testing

```python
# tests/test_integration.py
import pytest
from kernel_sdk import KernelApp

@pytest.fixture
def app():
    return KernelApp(
        name="Test App",
        tenant_id="test_tenant",
        api_key="test_key",
        kernel_host="localhost",
        kernel_port=9090
    )

def test_full_session_flow(app):
    # Start session
    session = app.session_manager.get_session(
        "test-session",
        "+263712345678"
    )
    
    # Navigate menus
    response = app.menu_router.get_handler("main")(session, "")
    assert "Welcome" in response.message
    
    response = app.menu_router.get_handler("main")(session, "1")
    assert response.next_menu == "check_balance"
```

---

## 8. Deployment

### 8.1 Dockerfile

```dockerfile
FROM python:3.12-slim

WORKDIR /app

# Install dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy application
COPY . .

# Expose port
EXPOSE 9000

# Health check
HEALTHCHECK --interval=30s --timeout=3s \
    CMD python -c "import requests; requests.get('http://localhost:9000/health')"

# Run
CMD ["python", "app.py"]
```

### 8.2 Kubernetes Deployment

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-ussd-app
spec:
  replicas: 2
  selector:
    matchLabels:
      app: my-ussd-app
  template:
    metadata:
      labels:
        app: my-ussd-app
    spec:
      containers:
        - name: app
          image: my-registry/my-ussd-app:latest
          ports:
            - containerPort: 9000
          env:
            - name: KERNEL_HOST
              value: "go-orchestrator.ussd-kernel.svc.cluster.local"
            - name: KERNEL_API_KEY
              valueFrom:
                secretKeyRef:
                  name: kernel-api-key
                  key: api-key
            - name: TENANT_ID
              value: "my_tenant_123"
---
apiVersion: v1
kind: Service
metadata:
  name: my-ussd-app
spec:
  selector:
    app: my-ussd-app
  ports:
    - port: 9000
      targetPort: 9000
```

---

## 9. Best Practices

### 9.1 Menu Design

```python
# ✅ GOOD: Clear, simple menus
@ussd.menu("main")
def main_menu(session, user_input):
    return ussd.MenuResponse(
        message="Select:\n1. Balance\n2. Transfer\n3. Help",
        options=["Balance", "Transfer", "Help"],
        type="CON"
    )

# ❌ BAD: Too many options, unclear text
@ussd.menu("main")
def bad_menu(session, user_input):
    return ussd.MenuResponse(
        message="Welcome to our amazing service! Please select from the following options: 1 for checking your account balance, 2 for transferring funds...",
        type="CON"
    )
```

### 9.2 Error Handling

```python
# ✅ GOOD: Graceful error handling
@ussd.menu("transfer_amount")
def transfer_amount(session, user_input):
    try:
        amount = float(user_input)
        if amount <= 0:
            raise ValueError()
        if amount > 10000:
            return ussd.MenuResponse(
                message="Amount exceeds limit. Max: $10,000",
                type="CON"
            )
    except ValueError:
        return ussd.MenuResponse(
            message="Please enter a valid number:",
            type="CON"
        )

# ❌ BAD: Uncaught exceptions
@ussd.menu("transfer_amount")
def bad_transfer(session, user_input):
    amount = float(user_input)  # Will crash on invalid input
```

### 9.3 State Management

```python
# ✅ GOOD: Minimal state, clear purpose
@ussd.menu("collect_info")
def collect_info(session, user_input):
    step = session.get("step", 1)
    
    if step == 1:
        session.set("name", user_input)
        session.set("step", 2)
        return ussd.MenuResponse(message="Enter phone:", type="CON")
    
    elif step == 2:
        session.set("phone", user_input)
        # Process and clear temp state
        process_application(session)
        session.delete("step")
        return ussd.end_session("Application submitted!")

# ❌ BAD: Storing unnecessary data
@ussd.menu("bad_example")
def bad_example(session, user_input):
    session.set("all_inputs", session.get("all_inputs", []) + [user_input])
    # Never cleaned up, grows indefinitely
```

---

## 10. Example: Complete Microfinance App

```python
# microfinance_app.py
"""
Complete microfinance USSD application example.
"""
from kernel_sdk import KernelApp, ussd, payment, ai
from decimal import Decimal

app = KernelApp(
    name="Rural MicroFinance",
    tenant_id="microfinance_zim",
    api_key="${API_KEY}"
)

# Language selection
@ussd.menu("language", welcome=True)
def select_language(session, user_input):
    if user_input == "":
        return ussd.MenuResponse(
            message="Select language:\n1. English\n2. Shona\n3. Ndebele",
            type="CON"
        )
    
    languages = {"1": "en", "2": "sn", "3": "nd"}
    if user_input in languages:
        session.set("language", languages[user_input])
        return ussd.goto("main")
    
    return ussd.MenuResponse(message="Invalid option. Try again:", type="CON")

# Main menu
@ussd.menu("main")
def main_menu(session, user_input):
    lang = session.get("language", "en")
    
    if user_input == "":
        text = translate("Welcome to Rural MicroFinance!\n1. Check Loan Status\n2. Apply for Loan\n3. Make Payment\n4. Check Balance", lang)
        return ussd.MenuResponse(message=text, type="CON")
    
    if user_input == "1":
        return ussd.goto("loan_status")
    elif user_input == "2":
        return ussd.goto("loan_apply_amount")
    elif user_input == "3":
        return ussd.goto("payment_amount")
    elif user_input == "4":
        return ussd.goto("check_balance")
    else:
        return ussd.MenuResponse(message=translate("Invalid option.", lang), type="CON")

# Loan application
@ussd.menu("loan_apply_amount")
def loan_apply_amount(session, user_input):
    lang = session.get("language", "en")
    
    if user_input == "":
        return ussd.MenuResponse(
            message=translate("Enter loan amount (USD):", lang),
            type="CON"
        )
    
    try:
        amount = Decimal(user_input)
        if amount < 50 or amount > 5000:
            return ussd.MenuResponse(
                message=translate("Amount must be between $50 and $5,000", lang),
                type="CON"
            )
        
        session.set("loan_amount", amount)
        return ussd.goto("loan_apply_purpose")
    except:
        return ussd.MenuResponse(
            message=translate("Invalid amount. Please enter a number:", lang),
            type="CON"
        )

@ussd.menu("loan_apply_purpose")
def loan_apply_purpose(session, user_input):
    lang = session.get("language", "en")
    
    if user_input == "":
        return ussd.MenuResponse(
            message=translate("Purpose:\n1. Business\n2. Agriculture\n3. Education\n4. Medical", lang),
            type="CON"
        )
    
    purposes = {"1": "business", "2": "agriculture", "3": "education", "4": "medical"}
    if user_input in purposes:
        session.set("loan_purpose", purposes[user_input])
        return ussd.goto("loan_apply_confirm")
    
    return ussd.MenuResponse(message=translate("Invalid option.", lang), type="CON")

@ussd.menu("loan_apply_confirm")
def loan_apply_confirm(session, user_input):
    lang = session.get("language", "en")
    amount = session.get("loan_amount")
    purpose = session.get("loan_purpose")
    
    if user_input == "":
        text = translate(f"Apply for ${amount} for {purpose}?\n1. Yes\n2. No", lang)
        return ussd.MenuResponse(message=text, type="CON")
    
    if user_input == "1":
        # Submit application
        application_id = submit_loan_application(session)
        
        # Emit event
        session.emit_event("LoanApplicationSubmitted", {
            "amount": str(amount),
            "purpose": purpose,
            "application_id": application_id
        })
        
        return ussd.end_session(
            translate(f"Application submitted! ID: {application_id}. You will receive an SMS shortly.", lang)
        )
    else:
        return ussd.end_session(translate("Application cancelled.", lang))

# Payment
@ussd.menu("payment_amount")
def payment_amount(session, user_input):
    lang = session.get("language", "en")
    
    if user_input == "":
        balance = get_loan_balance(session.get("phone_number"))
        text = translate(f"Outstanding: ${balance}\nEnter payment amount:", lang)
        return ussd.MenuResponse(message=text, type="CON")
    
    try:
        amount = Decimal(user_input)
        session.set("payment_amount", amount)
        return ussd.goto("payment_method")
    except:
        return ussd.MenuResponse(
            message=translate("Invalid amount.", lang),
            type="CON"
        )

@ussd.menu("payment_method")
def payment_method(session, user_input):
    lang = session.get("language", "en")
    
    if user_input == "":
        return ussd.MenuResponse(
            message=translate("Select method:\n1. EcoCash\n2. OneMoney\n3. Telecash", lang),
            type="CON"
        )
    
    providers = {"1": "ecocash", "2": "onemoney", "3": "telecash"}
    if user_input in providers:
        session.set("payment_provider", providers[user_input])
        return ussd.goto("payment_confirm")
    
    return ussd.MenuResponse(message=translate("Invalid option.", lang), type="CON")

@ussd.menu("payment_confirm")
def payment_confirm(session, user_input):
    lang = session.get("language", "en")
    amount = session.get("payment_amount")
    provider = session.get("payment_provider")
    
    if user_input == "":
        text = translate(f"Pay ${amount} via {provider}?\n1. Confirm\n2. Cancel", lang)
        return ussd.MenuResponse(message=text, type="CON")
    
    if user_input == "1":
        result = payment.initiate(
            provider=provider,
            phone=session.get("phone_number"),
            amount=float(amount),
            reference=f"loan_payment_{session.session_id}",
            description="Loan repayment"
        )
        
        if result.success:
            return ussd.end_session(
                translate("Payment initiated. You will receive a prompt on your phone.", lang)
            )
        else:
            return ussd.end_session(
                translate(f"Payment failed: {result.error_message}", lang)
            )
    else:
        return ussd.end_session(translate("Payment cancelled.", lang))

def translate(text: str, lang: str) -> str:
    """Translate text if not English."""
    if lang == "en":
        return text
    return ai.translate(text, lang)

def get_loan_balance(phone: str) -> Decimal:
    """Get outstanding loan balance."""
    # Implementation would query database
    return Decimal("250.00")

def submit_loan_application(session) -> str:
    """Submit loan application."""
    # Implementation would call API
    return "APP-12345"

if __name__ == "__main__":
    app.run()
```

---

**Status**: Implementation Ready  
**Next Steps**:
1. Implement SDK package structure
2. Create unit tests
3. Publish to PyPI
4. Create sample applications
