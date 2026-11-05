from django.test import SimpleTestCase
from django.urls import reverse


class SimulatorSmokeTests(SimpleTestCase):
    def test_public_auth_pages_are_available(self):
        self.assertEqual(self.client.get(reverse("login")).status_code, 200)
        self.assertEqual(self.client.get(reverse("register")).status_code, 200)

    def test_dashboard_requires_authentication(self):
        response = self.client.get(reverse("dashboard"))

        self.assertRedirects(response, reverse("login"))
