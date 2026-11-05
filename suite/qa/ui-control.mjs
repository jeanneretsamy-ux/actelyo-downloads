// The global project selector is behind OpenBousic's onboarding overlay.
// Verify the onboarding action itself, including opening and closing its dialog.
export async function assertActionableControl(page, applicationId, timeout=15000) {
  if (applicationId === 'openbousic' && new URL(page.url()).pathname === '/onboarding') {
    await page.getByTestId('onboarding-add-provider-button').click({timeout});
    await page.getByTestId('provider-modal-next').waitFor({state:'visible',timeout});
    await page.getByRole('button',{name:/^(Cancel|Annuler)$/}).click({timeout});
    await page.getByTestId('onboarding-add-provider-button').waitFor({state:'visible',timeout});
    return;
  }
  await page.locator('button:visible:not(:disabled)').first().click({trial:true,timeout});
}
