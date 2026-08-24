
## OPEN: business phone vs verified personal phone

Status: **undecided**. Implementation deliberately unchanged.

Current behaviour, in `register_screen.dart`:

    personal phone   → identity field. Required, E.164, verified by OTP.
    business phone   → contact detail on ws_tblorganization.
    business blank   → the personal number is used as the business phone.

The fallback predates phone verification, when both fields were plain contact
details. Now that one of them is a verified identity, silently copying it into
an organization record is a different act than it used to be: the organization's
public contact number becomes the owner's personal, verified line.

Two ways to settle it, neither of them a bug fix:

  a) business phone must always be entered separately — the identity number is
     never published as organization contact detail;
  b) the fallback stays, on the grounds that a one-person distributor genuinely
     has one number and being made to type it twice is friction for nothing.

Neither option needs a migration; `ws_tblorganization.phone` semantics are
unchanged either way. This is a product decision, recorded here so it is not
mistaken for an oversight and not "fixed" by whoever reads the code next.
