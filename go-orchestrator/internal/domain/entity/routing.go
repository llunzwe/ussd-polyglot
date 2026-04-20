package entity

type RouteRequest struct {
	SessionID   string
	PhoneNumber string
	UserInput   string
	CurrentMenu string
	ServiceCode string
	SessionState map[string]interface{}
	TenantID    string
}

type RouteResponse struct {
	MenuText           string
	Options            []string
	NextMenu           string
	UpdatedState       map[string]interface{}
	EndSession         bool
	PaymentInitiated   bool
	PaymentID          string
	ProviderReference  string
	PaymentStatus      string
}
