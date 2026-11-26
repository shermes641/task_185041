# Glossary (short)
- **Rate class**: one kind of charge (energy, basic, demand, reactive ...) with a cost unit and operation.
- **Pattern / pattern link**: maps month, weekday, hour to season and period for a rate class over a date window.
- **Cost operation**: the SQL function that prices a rate class from metering.
- **Rates**: stored in cents (cost = rate/100 * quantity). Monthly charges prorate by days.
- **Basic charge**: per point of supply per month, not per amp. Tariff 5's demand charge is R/Amp/phase/month.
