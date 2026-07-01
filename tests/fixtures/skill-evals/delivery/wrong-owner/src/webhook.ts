export async function handleInvoiceEvent(event: InvoiceEvent) {
  if (event.error === "timeout") {
    await provider.collect(event.invoiceId);
  }
}
