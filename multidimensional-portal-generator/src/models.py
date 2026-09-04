from sqlalchemy import JSON, Column, Float, Integer, String

from .database import Base


class PortalSimulationModel(Base):
    """
    Relational database model mapping physical
    simulation outcomes for historical audits.
    """

    __tablename__ = "portal_simulations"

    id = Column(Integer, primary_key=True, index=True)
    dimension_id = Column(Integer, nullable=False, index=True)
    initial_speed = Column(Float, nullable=False)
    object_mass = Column(Float, nullable=False)
    final_velocity = Column(Float, nullable=False)
    max_time_dilation = Column(Float, nullable=False)
    status = Column(String(50), nullable=False)
    simulation_metadata = Column(JSON, nullable=True)  # Stores sample coordinate
